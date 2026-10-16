//! 一个带 build.zig 的项目：管理构建系统协议进程、项目模型、编译集合与编译器诊断（设计 §11、§13）。
//!
//! 线程模型：每个 Workspace 有一个专用的后台任务阻塞读取 BSP 事件并处理；LSP 主循环只通过
//! `requestBuild` / `stop` 与之交互。
//!
//! 锁顺序：持有 `mutex` 时绝不开启查询引擎的写事务。诊断发布任务会在读事务中获取 `mutex`，
//! 而写事务要等所有读事务结束，交叉持有会死锁。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;

const za = @import("../zig_analyzer.zig");
const Server = @import("Server.zig");
const bsp = za.project.bsp;
const builtin = za.project.builtin;
const ZigEnv = za.project.ZigEnv;
const configuration = za.project.configuration;
const ProjectModel = za.base.ProjectModel;
const Vfs = za.base.Vfs;
const FileId = Vfs.FileId;
const compiler = za.diagnostics.compiler;
const CompileSet = za.diagnostics.compile_set;
const database = @import("../database.zig");
const FileText = database.inputs.FileText;
const AstCheck = database.live.AstCheck;

const Progress = Server.Progress.Progress;

const log = std.log.scoped(.workspace);

const Workspace = @This();

server: *Server,
gpa: Allocator,
/// 构建根目录（绝对路径，规范化）
root: []const u8,
/// 启动时的配置副本（构建参数、诊断 step）；配置变化时整个实例被重启替换
config: Server.Config,
/// 本实例是 maker 连续崩溃后自动重启的第几次（0 表示正常启动）
crash_restarts: u8 = 0,

mutex: Io.Mutex = .init,
// ── 以下字段受 mutex 保护 ──
client: ?*bsp.Client = null,
model: ?ProjectModel = null,
compile_set: ?CompileSet.Result = null,
/// 最近一次构建的编译器诊断
result: ?compiler.BuildResult = null,
/// FileId → `result` 中的条目
result_files: std.AutoArrayHashMapUnmanaged(FileId, *const compiler.FileResult) = .empty,
building: bool = false,
/// 至少完成过一次构建（用于判断崩溃是否「连续」）
built: bool = false,
/// 构建期间又收到构建请求：本轮结果作废，结束后立即重建
rebuild: bool = false,
/// 构建过程中得知了新的生成文件路径、但编译集合尚未重算（节流，见 `generated_recompute_interval_ms`）
generated_dirty: bool = false,
/// 上一次因生成文件重算编译集合的时间
generated_recomputed_at: ?Io.Timestamp = null,
stopping: bool = false,
/// 项目加载进度（启动到首次编译集合算出）
loading: ?*Progress = null,
/// 当前构建的进度与已完成的 step 数
build_progress: ?*Progress = null,
build_total: u32 = 0,
build_done: u32 = 0,
/// 被重启替换的旧实例发布过编译器诊断的文件：首次构建完成时一并重新发布，清除过时的诊断
stale_files: std.ArrayList(FileId) = .empty,
/// 诊断 step 及其传递依赖：只有这些 step 的错误作为编译器诊断发布
/// （构建请求中额外的生成文件产出 step 不影响诊断，与直接运行 `zig build <step>` 一致）
diag_steps: std.DynamicBitSetUnmanaged = .{},

// ── 以下字段只由后台任务访问 ──
bundles: std.ArrayList(ErrorBundle) = .empty,
/// 已尝试从磁盘加载的文件（不存在的文件也记录，避免反复尝试）
loaded: std.AutoHashMapUnmanaged(FileId, void) = .empty,

/// 构建过程中因生成文件的路径而重算编译集合的最短间隔
const generated_recompute_interval_ms = 1000;

/// 启动 maker 并在后台读取事件
pub fn start(server: *Server, root: []const u8, crash_restarts: u8) !*Workspace {
    const gpa = server.gpa;
    const env = server.zigEnv() orelse return error.ZigNotFound;
    const ws = try gpa.create(Workspace);
    errdefer gpa.destroy(ws);
    ws.* = .{ .server = server, .gpa = gpa, .root = try gpa.dupe(u8, root), .config = undefined, .crash_restarts = crash_restarts };
    errdefer gpa.free(ws.root);
    ws.config = try server.configSnapshot();
    errdefer ws.config.deinit(gpa);
    try loadProjectConfig(server, root, &ws.config);
    var title_buf: [256]u8 = undefined;
    ws.loading = server.progress.begin(server, std.fmt.bufPrint(&title_buf, "Loading project {s}", .{std.fs.path.basename(root)}) catch "Loading project", false);
    errdefer server.progress.end(server, ws.loading, null);
    ws.client = try bsp.Client.start(gpa, server.io, env.zig_exe, root, ws.config.build_args);
    errdefer ws.client.?.stop();
    server.busyBegin();
    try server.bg_group.concurrent(server.io, run, .{ws});
    return ws;
}

/// 以项目根目录的 `zig-analyzer.json` 覆盖配置；文件不存在时不变，有误时提示并忽略
fn loadProjectConfig(server: *Server, root: []const u8, config: *Server.Config) Allocator.Error!void {
    const gpa = server.gpa;
    const path = try std.fs.path.join(gpa, &.{ root, Server.Config.project_file });
    defer gpa.free(path);
    const text = Io.Dir.cwd().readFileAlloc(server.io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return,
        else => return log.warn("{s}: cannot read: {t}", .{ path, err }),
    };
    defer gpa.free(text);
    var project = Server.Config.parseProject(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => {
            var buf: [512]u8 = undefined;
            return server.showWarning(std.fmt.bufPrint(&buf, "{s} is not a valid JSON object, it is ignored", .{path}) catch path);
        },
    };
    defer project.deinit(gpa);
    server.reportConfigWarnings(path, &project);
    try config.overlayProject(gpa, &project);
}

/// 请求停止：maker 退出后后台任务结束并回收进程
pub fn stop(ws: *Workspace) void {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    ws.stopping = true;
    if (ws.client) |c| c.requestStop();
}

/// maker 连续崩溃时自动重启的次数上限
const max_crash_restarts = 3;

/// 后台任务全部结束后调用
pub fn destroy(ws: *Workspace) void {
    const gpa = ws.gpa;
    if (ws.model) |*m| m.deinit(gpa);
    if (ws.compile_set) |*s| s.deinit(gpa);
    if (ws.result) |*r| r.deinit(gpa);
    ws.result_files.deinit(gpa);
    ws.diag_steps.deinit(gpa);
    ws.stale_files.deinit(gpa);
    ws.config.deinit(gpa);
    for (ws.bundles.items) |*eb| eb.deinit(gpa);
    ws.bundles.deinit(gpa);
    ws.loaded.deinit(gpa);
    gpa.free(ws.root);
    gpa.destroy(ws);
}

/// 保存文件后请求构建；构建进行中时标记为结束后重建
pub fn requestBuild(ws: *Workspace) void {
    const io = ws.server.io;
    {
        ws.mutex.lockUncancelable(io);
        defer ws.mutex.unlock(io);
        const client = ws.client orelse return;
        const model = &(ws.model orelse return);
        if (ws.stopping) return;
        if (ws.building) {
            ws.rebuild = true;
            return;
        }
        const steps = model.buildSteps(ws.gpa, ws.config.compiler_diagnostics) catch return;
        defer ws.gpa.free(steps);
        if (steps.len != 0) {
            ws.building = true;
            ws.server.busyBegin();
            ws.build_progress = ws.server.progress.begin(ws.server, buildTitle(model, ws.config.compiler_diagnostics), true);
            sendBuild(ws, client, model, steps) catch |err| {
                log.err("failed to send build request: {t}", .{err});
                ws.building = false;
                ws.server.progress.end(ws.server, ws.build_progress, "Failed to send build request");
                ws.build_progress = null;
                ws.server.busyEnd();
            };
            return;
        }
    }
    // 不运行编译器且没有要产出的生成文件：不构建，按空结果完成一次（清除重启前发布的编译器诊断）
    ws.finishBuild() catch {};
}

/// 构建进度的标题：诊断 step 的名字；不运行编译器诊断时只构建生成文件
fn buildTitle(model: *const ProjectModel, with_diagnostics: bool) []const u8 {
    if (!with_diagnostics) return "zig build (generated files)";
    const S = struct {
        threadlocal var buf: [256]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    w.writeAll("zig build") catch {};
    for (model.diagnostics_steps) |s| w.print(" {s}", .{model.steps[s].name}) catch break;
    return w.buffered();
}

/// 发送构建请求并重置进度计数；调用方持有 mutex
fn sendBuild(ws: *Workspace, client: *bsp.Client, model: *const ProjectModel, steps: []const u32) !void {
    var closure = try model.dependencyClosure(ws.gpa, steps);
    defer closure.deinit(ws.gpa);
    ws.build_total = @intCast(closure.count());
    ws.build_done = 0;
    try client.buildSteps(steps);
}

/// 文件是否属于本项目：在编译集合中，或位于构建根目录下
pub fn owns(ws: *Workspace, file: FileId) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    if (ws.compile_set) |*s| if (s.contains(file)) return true;
    return isUnder(ws.server.vfs.path(file), ws.root);
}

/// 是否发布 live 诊断：编译集合尚未算出时发布；算出后只对集合中的文件发布（与编译器一致，§11.4）
pub fn liveEligible(ws: *Workspace, file: FileId) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    const set = &(ws.compile_set orelse return true);
    return set.contains(file);
}

pub fn isUnder(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or std.fs.path.isSep(path[dir.len]) or (dir.len > 0 and std.fs.path.isSep(dir[dir.len - 1]));
}

// ── 后台任务 ─────────────────────────────────────────────────────────

fn run(ws: *Workspace) Io.Cancelable!void {
    var started = true;
    // build.zig 编译失败后 maker 会退出，属于预期情况（保存 build.zig 时会重启）
    var config_failed = false;
    const client = ws.client.?;
    while (true) {
        var event = client.next() catch |err| {
            if (err == error.Canceled or ws.server.isShuttingDown()) {
                // 服务器退出：读取任务被取消，不是 maker 的问题
            } else if (config_failed) {
                log.info("{s}: build.zig failed to compile, build system exited; will restart when build.zig is saved", .{ws.root});
            } else if (!ws.isStopping()) {
                // maker 崩溃（如 0.17 的 maker 在收到新的构建请求时存在竞态，核数少时容易触发）：自动重启
                ws.mutex.lockUncancelable(ws.server.io);
                const next = if (ws.built) 1 else ws.crash_restarts + 1;
                ws.mutex.unlock(ws.server.io);
                if (next > max_crash_restarts) {
                    log.err("{s}: build system exited unexpectedly: {t} ({?t})", .{ ws.root, err, client.readError() });
                    ws.server.showWarning("zig build keeps exiting unexpectedly, compiler diagnostics are unavailable until build.zig is saved");
                } else {
                    log.info("{s}: build system exited unexpectedly ({t}, {?t}), restarting", .{ ws.root, err, client.readError() });
                    // 新实例计为忙碌后本实例才结束，waitIdle 不会在两者之间返回
                    ws.server.restartWorkspace(ws, next);
                }
            }
            break;
        };
        if (event == .configuration_failed) config_failed = true;
        defer event.deinit(ws.gpa);
        ws.handle(&event) catch |err| switch (err) {
            error.OutOfMemory => log.err("{s}: out of memory while handling build event", .{ws.root}),
        };
        // 首个构建图处理完（或构建图加载失败）后，启动阶段结束
        if (started and (event == .configuration or event == .configuration_failed)) {
            started = false;
            ws.server.busyEnd();
        }
    }
    ws.mutex.lockUncancelable(ws.server.io);
    const was_building = ws.building;
    ws.building = false;
    const c = ws.client;
    ws.client = null;
    ws.server.progress.end(ws.server, ws.build_progress, "Build interrupted");
    ws.build_progress = null;
    ws.server.progress.end(ws.server, ws.loading, if (config_failed) "build.zig has errors" else null);
    ws.loading = null;
    ws.mutex.unlock(ws.server.io);
    // 进度结束后才计为空闲：waitIdle（如 shutdown）返回前客户端已收到 end
    if (started) ws.server.busyEnd();
    if (was_building) ws.server.busyEnd();
    if (c) |cl| cl.deinit();
}

fn isStopping(ws: *Workspace) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    return ws.stopping;
}

fn handle(ws: *Workspace, event: *bsp.Event) Allocator.Error!void {
    const io = ws.server.io;
    switch (event.*) {
        .handshake => |h| if (h.version != bsp.protocol_version) {
            log.err("{s}: build system protocol version {d} does not match supported version {d}", .{ ws.root, h.version, bsp.protocol_version });
            ws.stop();
        },
        .configuration => |path| {
            const env = ws.server.zigEnv().?;
            if (!env.matchesBuiltin()) {
                ws.server.showWarningOnce("zig version differs from the one zig-analyzer was built with: cannot read the build graph, compiler diagnostics are unavailable");
                return;
            }
            ws.reportLoading("Reading build graph");
            var model = configuration.load(ws.gpa, io, ws.root, path, env) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("{s}: failed to read build graph: {t}", .{ ws.root, err });
                    return;
                },
            };
            try ws.generateBuiltins(&model);
            {
                const names = try ws.config.diagnosticsSteps(ws.gpa);
                defer if (names.ptr != ws.config.diagnostics_steps.ptr) ws.gpa.free(names);
                if (try model.setDiagnosticsSteps(ws.gpa, names) != 0) {
                    var buf: [256]u8 = undefined;
                    ws.server.showWarning(std.fmt.bufPrint(&buf, "some diagnostics.steps are not steps of {s}, they are ignored", .{ws.root}) catch "some diagnostics.steps are not steps of the project, they are ignored");
                }
            }
            {
                ws.mutex.lockUncancelable(io);
                defer ws.mutex.unlock(io);
                if (ws.model) |*old| old.deinit(ws.gpa);
                ws.model = model;
                ws.diag_steps.deinit(ws.gpa);
                ws.diag_steps = .{};
                // 不运行编译器诊断时没有诊断 step：构建中的错误不发布
                ws.diag_steps = if (ws.config.compiler_diagnostics)
                    try ws.model.?.dependencyClosure(ws.gpa, ws.model.?.diagnostics_steps)
                else
                    try .initEmpty(ws.gpa, ws.model.?.steps.len);
            }
            try ws.recomputeCompileSet();
            ws.mutex.lockUncancelable(io);
            ws.server.progress.end(ws.server, ws.loading, "Done");
            ws.loading = null;
            ws.mutex.unlock(io);
            ws.requestBuild();
        },
        .configuration_failed => |*eb| {
            // build.zig 本身有错：作为一次构建结果发布
            try ws.bundles.append(ws.gpa, eb.*);
            eb.* = .empty;
            try ws.finishBuild();
        },
        .step_started => |step| {
            ws.mutex.lockUncancelable(io);
            defer ws.mutex.unlock(io);
            const name = if (ws.model) |*m| if (step < m.steps.len) m.steps[step].name else null else null;
            ws.server.progress.report(ws.server, ws.build_progress, name, ws.build_done * 100 / @max(ws.build_total, 1));
        },
        .step_completed => |*sc| {
            var roots_changed = false;
            {
                ws.mutex.lockUncancelable(io);
                defer ws.mutex.unlock(io);
                ws.build_done += 1;
                const in_diag = sc.step < ws.diag_steps.bit_length and ws.diag_steps.isSet(sc.step);
                if (in_diag and sc.errors.errorMessageCount() != 0) {
                    try ws.bundles.append(ws.gpa, sc.errors);
                    sc.errors = .empty;
                }
                if (ws.model) |*m| for (sc.generated) |g| {
                    const path = try configuration.generatedPath(ws.gpa, ws.root, ws.server.zigEnv().?, g.prefix, g.sub_path);
                    defer ws.gpa.free(path);
                    if (try m.setGeneratedPath(ws.gpa, g.file, path)) roots_changed = true;
                };
            }
            // 生成的模块根文件路径刚刚得知（或变化）：不必等整个构建结束就更新编译集合，但要节流。
            // 大项目的构建图有上千个以生成文件为根的模块（如各测试变体的 build_options），逐个重算会使
            // 模块图更新上千次，每次都触发打开文件的诊断重新发布与其中的推导重算
            if (roots_changed) ws.generated_dirty = true;
            if (ws.generated_dirty) {
                const now = Io.Clock.awake.now(io);
                const due = if (ws.generated_recomputed_at) |t| t.durationTo(now).nanoseconds >= generated_recompute_interval_ms * std.time.ns_per_ms else true;
                if (due) {
                    ws.generated_dirty = false;
                    ws.generated_recomputed_at = now;
                    try ws.recomputeCompileSet();
                }
            }
        },
        .build_completed => {
            ws.mutex.lockUncancelable(io);
            ws.built = true;
            const rebuild = ws.rebuild;
            ws.rebuild = false;
            ws.mutex.unlock(io);
            if (rebuild) {
                // 构建期间文件又被保存：结果可能与磁盘不一致，丢弃并重建
                ws.clearBundles();
                ws.mutex.lockUncancelable(io);
                defer ws.mutex.unlock(io);
                ws.server.progress.report(ws.server, ws.build_progress, "Files changed, rebuilding", 0);
                if (ws.client) |c| if (ws.model) |*m| {
                    const steps = m.buildSteps(ws.gpa, ws.config.compiler_diagnostics) catch return;
                    defer ws.gpa.free(steps);
                    sendBuild(ws, c, m, steps) catch {};
                };
                return;
            }
            var errors: u32 = 0;
            for (ws.bundles.items) |eb| errors += eb.errorMessageCount();
            {
                var buf: [64]u8 = undefined;
                ws.mutex.lockUncancelable(io);
                defer ws.mutex.unlock(io);
                ws.server.progress.end(ws.server, ws.build_progress, if (errors == 0) "Done" else std.fmt.bufPrint(&buf, "{d} error(s)", .{errors}) catch null);
                ws.build_progress = null;
            }
            try ws.finishBuild();
            ws.generated_dirty = false;
            try ws.recomputeCompileSet();
            ws.mutex.lockUncancelable(io);
            ws.building = false;
            ws.mutex.unlock(io);
            ws.server.busyEnd();
        },
        else => {},
    }
}

/// 为每个模块生成 builtin.zig（相同参数只生成一次）
fn generateBuiltins(ws: *Workspace, model: *ProjectModel) Allocator.Error!void {
    const env = ws.server.zigEnv().?;
    const io = ws.server.io;
    ws.reportLoading("Generating builtin.zig");
    // 参数相同的模块共用一份；不同的参数并行生成（每份要启动一次编译器，命中参数记录时不启动）
    var unique: std.StringArrayHashMapUnmanaged(?[]u8) = .empty;
    defer {
        for (unique.keys(), unique.values()) |k, v| {
            ws.gpa.free(k);
            if (v) |p| ws.gpa.free(p);
        }
        unique.deinit(ws.gpa);
    }
    const slots = try ws.gpa.alloc(?usize, model.modules.len);
    defer ws.gpa.free(slots);
    for (model.modules, slots) |m, *slot| {
        slot.* = null;
        if (m.builtin_args.len == 0) continue;
        const key = try std.mem.join(ws.gpa, "\x00", m.builtin_args);
        const gop = try unique.getOrPut(ws.gpa, key);
        if (gop.found_existing) ws.gpa.free(key) else gop.value_ptr.* = null;
        slot.* = gop.index;
    }
    const args = try ws.gpa.alloc([]const []const u8, unique.count());
    defer ws.gpa.free(args);
    for (model.modules, slots) |m, slot| if (slot) |i| {
        args[i] = m.builtin_args;
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var group: Io.Group = .init;
    for (args, unique.values()) |a, *out| group.async(io, generateOne, .{ ws.gpa, io, env, a, out, &failed });
    group.await(io) catch {};
    if (failed.load(.acquire)) return error.OutOfMemory;
    for (slots, 0..) |slot, i| if (slot) |u| if (unique.values()[u]) |path| try model.setBuiltinFile(ws.gpa, @intCast(i), path);
}

fn generateOne(gpa: Allocator, io: Io, env: *const ZigEnv, args: []const []const u8, out: *?[]u8, failed: *std.atomic.Value(bool)) Io.Cancelable!void {
    out.* = builtin.generate(gpa, io, env, args) catch |err| switch (err) {
        error.OutOfMemory => blk: {
            failed.store(true, .release);
            break :blk null;
        },
        error.Canceled => return error.Canceled,
    };
}

fn reportLoading(ws: *Workspace, message: ?[]const u8) void {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    ws.server.progress.report(ws.server, ws.loading, message, null);
}

fn clearBundles(ws: *Workspace) void {
    for (ws.bundles.items) |*eb| eb.deinit(ws.gpa);
    ws.bundles.clearRetainingCapacity();
}

/// 把本轮收集的错误转换为诊断，替换上一轮结果，并重新发布受影响的文件
fn finishBuild(ws: *Workspace) Allocator.Error!void {
    defer ws.clearBundles();
    const build_zig = try std.fs.path.join(ws.gpa, &.{ ws.root, "build.zig" });
    defer ws.gpa.free(build_zig);
    var result = try compiler.collect(ws.gpa, ws.bundles.items, ws.root, build_zig, ws, readDisk);
    errdefer result.deinit(ws.gpa);

    var files: std.AutoArrayHashMapUnmanaged(FileId, *const compiler.FileResult) = .empty;
    errdefer files.deinit(ws.gpa);
    for (result.files.keys(), result.files.values()) |path, *fr| {
        try files.put(ws.gpa, try ws.server.vfs.intern(path), fr);
    }

    // 受影响的文件：上一轮与本轮有编译器诊断的文件
    var affected: std.ArrayList(FileId) = .empty;
    defer affected.deinit(ws.gpa);
    {
        const io = ws.server.io;
        ws.mutex.lockUncancelable(io);
        defer ws.mutex.unlock(io);
        try affected.appendSlice(ws.gpa, ws.result_files.keys());
        try affected.appendSlice(ws.gpa, files.keys());
        try affected.appendSlice(ws.gpa, ws.stale_files.items);
        ws.stale_files.clearAndFree(ws.gpa);
        if (ws.result) |*old| old.deinit(ws.gpa);
        ws.result_files.deinit(ws.gpa);
        // `files` 的值指向 `result.files` 的条目存储（在 arena 中），按值转移 `result` 后仍然有效
        ws.result = result;
        ws.result_files = files;
    }
    ws.server.publishFiles(affected.items, true);
}

fn readDisk(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    return Io.Dir.cwd().readFileAlloc(ws.server.io, path, gpa, .limited(Vfs.max_file_size)) catch null;
}

// ── 编译集合与文件加载 ────────────────────────────────────────────────

const Resolver = struct {
    ws: *Workspace,
    ctx: *database.Db.Ctx,

    pub fn intern(r: Resolver, file_path: []const u8) !FileId {
        return r.ws.server.vfs.intern(file_path);
    }

    pub fn path(r: Resolver, file: FileId) []const u8 {
        return r.ws.server.vfs.path(file);
    }

    pub fn imports(r: Resolver, file: FileId) !?[]const []const u8 {
        const text = try r.ctx.get(FileText, file);
        if (text == null) return if (r.ws.loaded.contains(file)) &.{} else null;
        return (try r.ctx.get(AstCheck, file)).imports;
    }
};

/// 计算编译集合；遇到未加载的文件时从磁盘加载后重算，直到没有缺失
pub fn recomputeCompileSet(ws: *Workspace) Allocator.Error!void {
    const io = ws.server.io;
    var steps: []u32 = &.{};
    defer ws.gpa.free(steps);
    {
        ws.mutex.lockUncancelable(io);
        defer ws.mutex.unlock(io);
        const model = &(ws.model orelse return);
        steps = try model.compileStepsOf(ws.gpa, model.diagnostics_steps);
    }

    var rounds: usize = 0;
    while (rounds < 256) : (rounds += 1) {
        var arena: std.heap.ArenaAllocator = .init(ws.gpa);
        defer arena.deinit();
        var result = blk: {
            var ctx = ws.server.db.beginRead(arena.allocator());
            defer ctx.end();
            ws.mutex.lockUncancelable(io);
            // model 只在本任务中替换，可安全地在锁外使用其指针
            const model = &ws.model.?;
            ws.mutex.unlock(io);
            break :blk CompileSet.compute(ws.gpa, model, steps, Resolver{ .ws = ws, .ctx = &ctx }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // 被编辑打断：重试
                error.Canceled => continue,
            };
        };
        if (result.missing.count() == 0) {
            ws.mutex.lockUncancelable(io);
            if (ws.compile_set) |*old| old.deinit(ws.gpa);
            ws.compile_set = result;
            ws.mutex.unlock(io);
            // 编译集合变化会影响模块归属与已打开文件的 live 诊断
            ws.server.updateModuleGraph();
            ws.server.publishOpenFiles();
            return;
        }
        defer result.deinit(ws.gpa);
        var buf: [64]u8 = undefined;
        ws.reportLoading(std.fmt.bufPrint(&buf, "Analyzing compile set ({d} files)", .{result.files.count()}) catch null);
        try ws.loadFiles(result.missing.keys());
    }
    log.warn("{s}: compile set computation did not converge", .{ws.root});
}

fn loadFiles(ws: *Workspace, files: []const FileId) Allocator.Error!void {
    const Loaded = struct { file: FileId, text: ?[]u8, durability: database.Durability };
    var batch: std.ArrayList(Loaded) = .empty;
    defer batch.deinit(ws.gpa);
    for (files) |file| {
        try ws.loaded.put(ws.gpa, file, {});
        const path = ws.server.vfs.path(file);
        const text = ws.server.vfs.readFromDisk(file, ws.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        try batch.append(ws.gpa, .{ .file = file, .text = text, .durability = ws.server.fileDurability(path) });
    }
    const db = &ws.server.db;
    db.beginWrite();
    defer db.endWrite();
    for (batch.items) |l| {
        // 期间被客户端打开的文件以缓冲区为准
        if (db.peek(FileText, l.file) != null) {
            if (l.text) |t| ws.gpa.free(t);
            continue;
        }
        try db.set(FileText, l.file, l.text, l.durability);
    }
}
