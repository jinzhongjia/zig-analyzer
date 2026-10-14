//! LSP 基准（设计 §1 的性能预算）：以子进程启动 zig-analyzer，经标准输入输出按真实编辑器的方式交互，
//! 测量冷启动各阶段、热状态下 hover / goto / completion 的延迟分布、编辑到诊断的延迟与常驻内存。
//!
//! 用法：zig build bench -Doptimize=ReleaseSafe -- <项目根目录> <文件（相对项目根）>...
//!
//! 请求位置在文件中按标识符均匀取样（每个文件最多 `samples` 处），补全取 `.` 之后的位置。
//!
//! 环境变量：
//! - `BENCH_CONFIG`：回复 `workspace/configuration` 的配置（JSON），如 `{"build":{"args":["-Dno-bin"]}}`
//! - `BENCH_SAVE=1`：测量保存 → 构建完成（会改写项目中的文件，结束时恢复）
//! - `BENCH_HOVER=行:列`：打印该处的 hover 结果
//! - `BENCH_VERBOSE=1`：打印首轮中较慢的请求、其内存变化与各 query 的执行次数

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const za = @import("zig_analyzer");
const transport = za.lsp.transport;

const samples = 200;
/// 打印首轮中耗时超过 20ms 的请求及其内存变化（BENCH_VERBOSE=1）
var verbose = false;

fn lineText(text: []const u8, line: u32) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: u32 = 0;
    while (it.next()) |l| : (i += 1) if (i == line) return std.mem.trim(u8, l, " ");
    return "";
}

const Client = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    read_buffer: [64 * 1024]u8 = undefined,
    write_buffer: [64 * 1024]u8 = undefined,
    next_id: i64 = 1,
    arena: std.heap.ArenaAllocator,
    start: Io.Timestamp = undefined,
    /// 回复 `workspace/configuration` 的配置（BENCH_CONFIG，JSON）
    config: json.Value = .null,
    /// 已结束的构建进度数（标题以 `zig build` 开头的进度）
    builds_done: usize = 0,
    build_tokens: std.ArrayList([]const u8) = .empty,
    /// 最近一次构建结束时的消息（如 `1 error(s)`）
    build_message: []const u8 = "",

    fn send(c: *Client, value: anytype) !void {
        const body = try json.Stringify.valueAlloc(c.gpa, value, .{ .emit_null_optional_fields = false });
        defer c.gpa.free(body);
        const w = &c.writer.interface;
        try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try w.writeAll(body);
        try w.flush();
    }

    fn notify(c: *Client, method: []const u8, params: anytype) !void {
        try c.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    /// 读取下一条消息；服务器发来的请求当场回复（配置为空，其余为 null）
    fn next(c: *Client) !json.Value {
        while (true) {
            const body = try transport.readMessage(&c.reader.interface, c.arena.allocator());
            const msg = try json.parseFromSliceLeaky(json.Value, c.arena.allocator(), body, .{});
            const method = msg.object.get("method") orelse return msg;
            // 进度事件：打印时间线
            if (std.mem.eql(u8, method.string, "$/progress")) {
                const v = msg.object.get("params").?.object.get("value").?.object;
                const kind = v.get("kind").?.string;
                if (!std.mem.eql(u8, kind, "report")) {
                    const title = if (v.get("title")) |t| t.string else if (v.get("message")) |m| m.string else "";
                    if (verbose or c.builds_done == 0) std.debug.print("    [{d:>8.0}ms] progress {s} {s}\n", .{ ms(c.io, c.start), kind, title });
                    const token = try json.Stringify.valueAlloc(c.arena.allocator(), msg.object.get("params").?.object.get("token").?, .{});
                    if (std.mem.eql(u8, kind, "begin") and std.mem.startsWith(u8, title, "zig build")) try c.build_tokens.append(c.arena.allocator(), token);
                    if (std.mem.eql(u8, kind, "end")) for (c.build_tokens.items) |t| if (std.mem.eql(u8, t, token)) {
                        c.builds_done += 1;
                        c.build_message = title;
                    };
                }
            }
            const id = msg.object.get("id") orelse return msg;
            if (std.mem.eql(u8, method.string, "workspace/configuration")) {
                try c.send(.{ .jsonrpc = "2.0", .id = id, .result = &[_]json.Value{c.config} });
            } else {
                try c.send(.{ .jsonrpc = "2.0", .id = id, .result = null });
            }
        }
    }

    /// 发送请求并等待其响应，返回响应与耗时（毫秒）
    fn request(c: *Client, method: []const u8, params: anytype) !struct { json.Value, f64 } {
        const id = c.next_id;
        c.next_id += 1;
        const t0 = Io.Clock.awake.now(c.io);
        if (@TypeOf(params) == void) {
            try c.send(.{ .jsonrpc = "2.0", .id = id, .method = method });
        } else {
            try c.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        }
        while (true) {
            const msg = try c.next();
            if (msg.object.get("method") != null) continue;
            const got = msg.object.get("id") orelse continue;
            if (got == .integer and got.integer == id) return .{ msg, ms(c.io, t0) };
        }
    }

    /// 等待 `uri` 的诊断满足 `pred`，返回耗时
    fn waitDiagnostics(c: *Client, uri: []const u8, t0: Io.Timestamp, comptime pred: fn (usize) bool) !f64 {
        while (true) {
            const msg = try c.next();
            const method = msg.object.get("method") orelse continue;
            if (!std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) continue;
            const params = msg.object.get("params").?.object;
            if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
            if (pred(params.get("diagnostics").?.array.items.len)) return ms(c.io, t0);
        }
    }
};

fn ms(io: Io, t0: Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_ms;
}

const Position = struct { line: u32, character: u32 };

fn positionOf(text: []const u8, offset: usize) Position {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

/// 按标识符均匀取样的位置；`after_dot` 时取 `a.b` 中 `.` 之后的位置
fn samplePositions(a: Allocator, text: [:0]const u8, after_dot: bool) ![]Position {
    var all: std.ArrayList(usize) = .empty;
    var tokenizer: std.zig.Tokenizer = .init(text);
    var prev: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof) break;
        if (t.tag == .identifier) {
            if (!after_dot) try all.append(a, t.loc.start) else if (prev == .period) try all.append(a, t.loc.start);
        }
        prev = t.tag;
    }
    const n = @min(all.items.len, samples);
    const out = try a.alloc(Position, n);
    for (out, 0..) |*p, i| p.* = positionOf(text, all.items[i * all.items.len / n]);
    return out;
}

const Stats = struct {
    fn print(name: []const u8, times: []f64) void {
        if (times.len == 0) return;
        std.mem.sort(f64, times, {}, std.sort.asc(f64));
        const p = struct {
            fn at(t: []const f64, q: f64) f64 {
                return t[@min(t.len - 1, @as(usize, @intFromFloat(q * @as(f64, @floatFromInt(t.len)))))];
            }
        }.at;
        std.debug.print("  {s:<12} n={d:<4} p50 {d:>7.1}ms  p95 {d:>7.1}ms  max {d:>7.1}ms\n", .{ name, times.len, p(times, 0.5), p(times, 0.95), times[times.len - 1] });
    }
};

const QueryCount = struct { name: []const u8, n: i64 };

/// 各查询的累计执行次数（zig-analyzer/status）
fn queryCounts(c: *Client) ![]QueryCount {
    const resp, _ = try c.request("zig-analyzer/status", {});
    const qs = resp.object.get("result").?.object.get("queries").?.array.items;
    const out = try c.arena.allocator().alloc(QueryCount, qs.len);
    for (qs, out) |q, *o| o.* = .{ .name = q.object.get("name").?.string, .n = q.object.get("executions").?.integer };
    return out;
}

fn rssMb(gpa: Allocator, io: Io, pid: std.process.Child.Id) !?f64 {
    const pid_str = try std.fmt.allocPrint(gpa, "{d}", .{pid});
    defer gpa.free(pid_str);
    const r = std.process.run(gpa, io, .{ .argv = &.{ "ps", "-o", "rss=", "-p", pid_str } }) catch return null;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const kb = std.fmt.parseInt(u64, std.mem.trim(u8, r.stdout, " \n"), 10) catch return null;
    return @as(f64, @floatFromInt(kb)) / 1024;
}

fn notEmpty(n: usize) bool {
    return n > 0;
}

fn isEmpty(n: usize) bool {
    return n == 0;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.debug.print("usage: {s} <zig-analyzer> <project root> <file>...\n", .{args[0]});
        return 2;
    }
    verbose = init.environ_map.get("BENCH_VERBOSE") != null;
    const root = try Io.Dir.cwd().realPathFileAlloc(io, args[2], gpa);
    defer gpa.free(root);

    var c: Client = .{ .gpa = gpa, .io = io, .child = undefined, .reader = undefined, .writer = undefined, .arena = .init(gpa) };
    defer c.arena.deinit();
    const t_spawn = Io.Clock.awake.now(io);
    c.start = t_spawn;
    c.child = try std.process.spawn(io, .{ .argv = &.{args[1]}, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
    c.reader = c.child.stdout.?.readerStreaming(io, &c.read_buffer);
    c.writer = c.child.stdin.?.writerStreaming(io, &c.write_buffer);

    const a = c.arena.allocator();
    if (init.environ_map.get("BENCH_CONFIG")) |cfg| c.config = try json.parseFromSliceLeaky(json.Value, a, cfg, .{});
    const root_uri = try za.base.uri.fromPath(a, root);
    _ = try c.request("initialize", .{
        .rootUri = root_uri,
        .capabilities = .{ .workspace = .{ .configuration = true }, .window = .{ .workDoneProgress = true } },
    });
    std.debug.print("cold start\n  initialize   {d:.1}ms\n", .{ms(io, t_spawn)});
    try c.notify("initialized", struct {}{});

    for (args[3..]) |rel| {
        const path = try std.fs.path.join(a, &.{ root, rel });
        const text = try Io.Dir.cwd().readFileAllocOptions(io, path, a, .unlimited, .of(u8), 0);
        const uri = try za.base.uri.fromPath(a, path);
        const doc = .{ .uri = uri };
        std.debug.print("{s} ({d} lines)\n", .{ rel, std.mem.count(u8, text, "\n") });

        const t_open = Io.Clock.awake.now(io);
        try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
        _ = try c.request("textDocument/documentSymbol", .{ .textDocument = doc });
        std.debug.print("  open → syntax          {d:.1}ms\n", .{ms(io, t_open)});
        const first = samplePositions(a, text, false) catch unreachable;
        _, const first_hover = try c.request("textDocument/hover", .{ .textDocument = doc, .position = first[first.len / 2] });
        std.debug.print("  first hover            {d:.1}ms (open → {d:.1}ms)\n", .{ first_hover, ms(io, t_open) });
        _ = try c.request("zig-analyzer/waitIdle", {});
        std.debug.print("  open → project idle    {d:.1}ms\n", .{ms(io, t_open)});
        if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("  memory after idle {d:.0} MB\n", .{mb});
        _, const first_after = try c.request("textDocument/hover", .{ .textDocument = doc, .position = first[0] });
        std.debug.print("  first hover after idle {d:.1}ms\n", .{first_after});
        // BENCH_HOVER=行:列：打印该处的 hover 结果与耗时
        if (init.environ_map.get("BENCH_HOVER")) |spec| {
            var it = std.mem.splitScalar(u8, spec, ':');
            const line = try std.fmt.parseInt(u32, it.next().?, 10);
            const col = try std.fmt.parseInt(u32, it.next().?, 10);
            const resp, const t = try c.request("textDocument/hover", .{ .textDocument = doc, .position = Position{ .line = line - 1, .character = col - 1 } });
            std.debug.print("  hover {s}: {d:.1}ms\n{f}\n", .{ spec, t, json.fmt(resp.object.get("result").?, .{}) });
            if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("  memory {d:.0} MB\n", .{mb});
        }

        // 热状态：同一批位置先预热一轮，再计时
        const idents = try samplePositions(a, text, false);
        const dots = try samplePositions(a, text, true);
        inline for (.{ "textDocument/hover", "textDocument/definition", "textDocument/completion" }) |method| {
            const positions = if (comptime std.mem.eql(u8, method, "textDocument/completion")) dots else idents;
            const times = try a.alloc(f64, positions.len);
            var cold_max: f64 = 0;
            for (positions) |p| {
                const before = if (verbose) try rssMb(gpa, io, c.child.id.?) else null;
                const counts_before = if (verbose) try queryCounts(&c) else null;
                _, const t = try c.request(method, .{ .textDocument = doc, .position = p });
                cold_max = @max(cold_max, t);
                if (verbose and t > 20) {
                    const after = try rssMb(gpa, io, c.child.id.?);
                    std.debug.print("    slow {s} {d}:{d} {d:.1}ms memory {d:.0} → {d:.0} MB  `{s}`\n", .{ method["textDocument/".len..], p.line + 1, p.character + 1, t, before.?, after.?, lineText(text, p.line) });
                    const counts_after = try queryCounts(&c);
                    for (counts_after, counts_before.?) |x, y| if (x.n != y.n) std.debug.print("      {s}: +{d}\n", .{ x.name, x.n - y.n });
                }
            }
            var hits: usize = 0;
            for (positions, times) |p, *t| {
                const resp, t.* = try c.request(method, .{ .textDocument = doc, .position = p });
                if (resp.object.get("result")) |r| if (r != .null) {
                    hits += 1;
                };
            }
            Stats.print(method["textDocument/".len..], times);
            if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("  {s:<12} memory {d:.0} MB\n", .{ "", mb });
            std.debug.print("  {s:<12} non-null {d}/{d}\n", .{ "", hits, positions.len });
            std.debug.print("  {s:<12} first pass max {d:.1}ms\n", .{ "", cold_max });
        }

        // 编辑 → live 诊断：在文件末尾加入语法错误，再撤销
        {
            const end = positionOf(text, text.len);
            var edit_times: [10]f64 = undefined;
            var clear_times: [10]f64 = undefined;
            var version: i64 = 2;
            for (&edit_times, &clear_times) |*te, *tc| {
                var t0 = Io.Clock.awake.now(io);
                try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = end, .end = end }, .text = "@@" }} });
                version += 1;
                te.* = try c.waitDiagnostics(uri, t0, notEmpty);
                t0 = Io.Clock.awake.now(io);
                const after: Position = .{ .line = end.line, .character = end.character + 2 };
                try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = end, .end = after }, .text = "" }} });
                version += 1;
                tc.* = try c.waitDiagnostics(uri, t0, isEmpty);
            }
            Stats.print("edit→diag", &edit_times);
            Stats.print("undo→clear", &clear_times);

            // 保存 → 编译器诊断（BENCH_SAVE=1）：在磁盘文件末尾写入一个语义错误（AstGen 不报，只有编译器报），
            // 保存后等诊断出现，再恢复原文件并等诊断清除。会改写项目中的文件，结束时恢复
            if (init.environ_map.get("BENCH_SAVE") != null) {
                const bad = try std.mem.concat(a, u8, &.{ text, "\ncomptime {\n    _ = @as(u8, 300);\n}\n" });
                var save_times: [5]f64 = undefined;
                var restore_times: [5]f64 = undefined;
                defer Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
                // 计时到本次保存触发的构建结束（诊断随之发布）
                for (&save_times, &restore_times) |*ts, *tr| {
                    for ([_][]const u8{ bad, text }, [_]*f64{ ts, tr }) |content, out| {
                        _ = try c.request("zig-analyzer/waitIdle", {});
                        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
                        try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = content }} });
                        version += 1;
                        const done = c.builds_done;
                        const t0 = Io.Clock.awake.now(io);
                        try c.notify("textDocument/didSave", .{ .textDocument = doc });
                        while (c.builds_done == done) _ = try c.next();
                        out.* = ms(io, t0);
                        if (verbose) std.debug.print("    save: {s}\n", .{c.build_message});
                    }
                }
                Stats.print("save→build", &save_times);
                Stats.print("restore", &restore_times);
            }
        }
    }
    if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("resident memory {d:.0} MB\n", .{mb});
    _ = try c.request("shutdown", {});
    try c.send(.{ .jsonrpc = "2.0", .method = "exit" });
    _ = try c.child.wait(io);
    return 0;
}
