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
//! - `BENCH_CHECK=<n>`：校验跳转的正确性：对文件中的标识符请求 declaration，目标处的标识符应与请求处相同；
//!   同时打印前 n 个未解析的标识符
//! - `BENCH_QUICK=1`：跳过编辑、连续输入与保存的各阶段（批量校验大量项目时使用）
//! - `BENCH_COMPLETE=<n>`：补全的召回：源码中的成员访问 `a.b` 在 `.` 之后补全，列表中应有 `b`
//! - `BENCH_REFS=<n>`：校验 n 个声明的查找引用与重命名（同名、无误报、本文件无漏报、rename 与引用一致）
//! - `BENCH_SESSION=<轮数>`：长时间会话，观察内存的增长

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
    /// 各文件最近一次发布的错误诊断个数（按 uri）
    errors: std.StringHashMapUnmanaged(usize) = .empty,
    last_counts: []const QueryCount = &.{},
    /// 跳转校验中打印的未解析样例数（BENCH_CHECK 的值）
    unresolved_samples: usize = 0,

    fn send(c: *Client, value: anytype) !void {
        const body = try json.Stringify.valueAlloc(c.gpa, value, .{ .emit_null_optional_fields = false });
        defer c.gpa.free(body);
        const w = &c.writer.interface;
        try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try w.writeAll(body);
        try w.flush();
    }

    /// 上一个阶段以来各 query 的执行次数与累计耗时的增量（BENCH_VERBOSE）
    fn phase(c: *Client, name: []const u8) !void {
        const now = try queryCounts(c);
        const st, _ = try c.request("zig-analyzer/status", {});
        std.debug.print("    phase `{s}` (revision {d}):", .{ name, st.object.get("result").?.object.get("revision").?.integer });
        for (now) |q| {
            const before: QueryCount = for (c.last_counts) |b| {
                if (std.mem.eql(u8, b.name, q.name)) break b;
            } else .{ .name = q.name, .n = 0, .ms = 0 };
            if (q.n != before.n) std.debug.print(" {s} +{d} ({d:.0} ms)", .{ za.db_report.shortName(q.name), q.n - before.n, q.ms - before.ms });
        }
        std.debug.print("\n", .{});
        c.last_counts = now;
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
            if (std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) {
                const params = msg.object.get("params").?.object;
                var errors: usize = 0;
                for (params.get("diagnostics").?.array.items) |d| {
                    const severity = d.object.get("severity") orelse continue;
                    if (severity == .integer and severity.integer == 1) errors += 1;
                }
                const uri = params.get("uri").?.string;
                const entry = try c.errors.getOrPut(c.arena.allocator(), uri);
                if (!entry.found_existing) entry.key_ptr.* = try c.arena.allocator().dupe(u8, uri);
                entry.value_ptr.* = errors;
            }
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

    /// 等待 `uri` 的错误诊断个数满足 `pred`，返回耗时（提示等其他级别不计，如非活动代码）
    fn waitDiagnostics(c: *Client, uri: []const u8, t0: Io.Timestamp, comptime pred: fn (usize, usize) bool, base: usize) !f64 {
        while (true) {
            const msg = try c.next();
            const method = msg.object.get("method") orelse continue;
            if (!std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) continue;
            const params = msg.object.get("params").?.object;
            if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
            if (pred(c.errors.get(uri).?, base)) return ms(c.io, t0);
        }
    }

    /// `uri` 当前的错误诊断个数：先等后台工作结束，使之是当前文本的结果。
    /// 标准库等文件本身可能带有错误，编辑的计时以此为基准
    fn baseErrors(c: *Client, uri: []const u8) !usize {
        _ = try c.request("zig-analyzer/waitIdle", {});
        return c.errors.get(uri) orelse 0;
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

const QueryCount = struct { name: []const u8, n: i64, ms: f64 = 0 };

/// 各查询的累计执行次数（zig-analyzer/status）
fn queryCounts(c: *Client) ![]QueryCount {
    const resp, _ = try c.request("zig-analyzer/status", {});
    const qs = resp.object.get("result").?.object.get("queries").?.array.items;
    const out = try c.arena.allocator().alloc(QueryCount, qs.len);
    for (qs, out) |q, *o| {
        const t = q.object.get("total_ms").?;
        o.* = .{ .name = q.object.get("name").?.string, .n = q.object.get("executions").?.integer, .ms = switch (t) {
            .float => |f| f,
            .integer => |x| @floatFromInt(x),
            else => 0,
        } };
    }
    return out;
}

/// 服务器整个运行期间各 query 的耗时（zig-analyzer/status），按自身耗时排序
fn printQueryTable(c: *Client) !void {
    const resp, _ = try c.request("zig-analyzer/status", {});
    const qs = resp.object.get("result").?.object.get("queries").?.array.items;
    const a = c.arena.allocator();
    const names = try a.alloc([]const u8, qs.len);
    const stats = try a.alloc(za.db.QueryStats, qs.len);
    const ns = struct {
        fn of(v: json.Value) u64 {
            const f: f64 = switch (v) {
                .float => |x| x,
                .integer => |x| @floatFromInt(x),
                else => 0,
            };
            return @intFromFloat(f * std.time.ns_per_ms);
        }
    }.of;
    for (qs, names, stats) |q, *n, *st| {
        const o = q.object;
        n.* = o.get("name").?.string;
        st.* = .{
            .executions = @intCast(o.get("executions").?.integer),
            .hits = @intCast(o.get("hits").?.integer),
            .cutoffs = @intCast(o.get("cutoffs").?.integer),
            .total_ns = ns(o.get("total_ms").?),
            .self_ns = ns(o.get("self_ms").?),
            .max_ns = ns(o.get("max_ms").?),
            .memos = @intCast(o.get("memos").?.integer),
        };
    }
    var out: std.Io.Writer.Allocating = .init(a);
    try za.db_report.writeTable(&out.writer, names, stats, 12);
    std.debug.print("queries (whole run):\n{s}", .{out.written()});
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

/// 位置（行、UTF-16 列；样例文件都是 ASCII 时等于字节列）对应的字节偏移
fn offsetOf(text: []const u8, p: Position) ?usize {
    var line: u32 = 0;
    var start: usize = 0;
    while (line < p.line) : (line += 1) start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null) + 1;
    return if (start + p.character <= text.len) start + p.character else null;
}

/// 偏移处的标识符（含 `@"..."` 形式）
fn identAt(text: []const u8, offset: usize) []const u8 {
    if (std.mem.startsWith(u8, text[offset..], "@\"")) {
        const end = std.mem.indexOfScalarPos(u8, text, offset + 2, '"') orelse return "";
        return text[offset + 2 .. end];
    }
    var end = offset;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    return text[offset..end];
}

/// 跳转的正确性（BENCH_CHECK=1）：对文件中的每个标识符（最多 `limit` 个，均匀取样）请求
/// `textDocument/declaration`，目标位置的标识符应与请求处的相同（declaration 不追别名链）
fn checkDeclarations(c: *Client, uri: []const u8, text: [:0]const u8, rel: []const u8) !void {
    const a = c.arena.allocator();
    const limit = 3000;
    var offsets: std.ArrayList(usize) = .empty;
    // 每个标识符之前的两个 token，用于给未解析的标识符分类
    var befores: std.ArrayList([2]std.zig.Token.Tag) = .empty;
    var tokenizer: std.zig.Tokenizer = .init(text);
    var prev: [2]std.zig.Token.Tag = .{ .invalid, .invalid };
    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof) break;
        // `[*c]` 中的 `c` 是指针语法的一部分，不是名字
        const c_ptr = prev[0] == .l_bracket and prev[1] == .asterisk and std.mem.eql(u8, text[t.loc.start..t.loc.end], "c");
        if (t.tag == .identifier and !c_ptr and !std.mem.eql(u8, text[t.loc.start..t.loc.end], "_")) {
            try offsets.append(a, t.loc.start);
            try befores.append(a, prev);
        }
        prev = .{ prev[1], t.tag };
    }
    var kinds: [@typeInfo(UnresolvedKind).@"enum".field_names.len]usize = @splat(0);
    const n = @min(offsets.items.len, limit);
    var texts: std.StringHashMapUnmanaged([]const u8) = .empty;
    var resolved: usize = 0;
    var mismatched: usize = 0;
    var samples_shown: usize = 0;
    var unresolved_shown: usize = 0;
    // BENCH_CHECK=<n>：打印前 n 个未解析的标识符
    const unresolved_limit = c.unresolved_samples;
    for (0..n) |i| {
        const off = offsets.items[i * offsets.items.len / n];
        const before = befores.items[i * offsets.items.len / n];
        const name = identAt(text, off);
        const resp, _ = try c.request("textDocument/declaration", .{ .textDocument = .{ .uri = uri }, .position = positionOf(text, off) });
        const result = resp.object.get("result") orelse continue;
        const loc = switch (result) {
            .object => result,
            .array => |arr| if (arr.items.len > 0) arr.items[0] else null,
            else => null,
        } orelse {
            kinds[@intFromEnum(classifyUnresolved(name, before))] += 1;
            if (unresolved_shown < unresolved_limit) {
                unresolved_shown += 1;
                const p = positionOf(text, off);
                const line_start = off - p.character;
                const line_end = std.mem.indexOfScalarPos(u8, text, off, '\n') orelse text.len;
                std.debug.print("    unresolved {s}:{d}:{d} `{s}`  | {s}\n", .{ rel, p.line + 1, p.character + 1, name, std.mem.trim(u8, text[line_start..line_end], " ") });
            }
            continue;
        };
        resolved += 1;
        const target_uri = loc.object.get("uri").?.string;
        const start = loc.object.get("range").?.object.get("start").?.object;
        const target_text = texts.get(target_uri) orelse blk: {
            const path = za.base.uri.toPath(a, target_uri) catch break :blk "";
            const t = Io.Dir.cwd().readFileAlloc(c.io, path, a, .limited(16 * 1024 * 1024)) catch "";
            try texts.put(a, target_uri, t);
            break :blk t;
        };
        const target_off = offsetOf(target_text, .{ .line = @intCast(start.get("line").?.integer), .character = @intCast(start.get("character").?.integer) }) orelse continue;
        const target_name = identAt(target_text, target_off);
        if (std.mem.eql(u8, name, target_name)) continue;
        mismatched += 1;
        if (samples_shown < 12) {
            samples_shown += 1;
            const p = positionOf(text, off);
            const tp = positionOf(target_text, target_off);
            std.debug.print("    mismatch {s}:{d}:{d} `{s}` -> {s}:{d}:{d} `{s}`\n", .{ rel, p.line + 1, p.character + 1, name, std.fs.path.basename(target_uri), tp.line + 1, tp.character + 1, target_name });
        }
    }
    std.debug.print("  declaration  checked {d} identifiers: resolved {d} ({d:.1}%), mismatched {d}\n", .{ n, resolved, @as(f64, @floatFromInt(resolved)) * 100 / @as(f64, @floatFromInt(@max(n, 1))), mismatched });
    std.debug.print("  declaration  unresolved by kind:", .{});
    for (kinds, 0..) |k, i| std.debug.print(" {t} {d}", .{ @as(UnresolvedKind, @enumFromInt(i)), k });
    // 内置类型与值、len / ptr、error.X 本来就没有声明位置，不计入分母
    const no_decl = kinds[@intFromEnum(UnresolvedKind.primitive)] + kinds[@intFromEnum(UnresolvedKind.len_ptr)] + kinds[@intFromEnum(UnresolvedKind.error_name)];
    std.debug.print("; resolved excluding identifiers without a declaration {d:.1}%\n", .{@as(f64, @floatFromInt(resolved)) * 100 / @as(f64, @floatFromInt(@max(n - no_decl, 1)))});
}

/// 未解析的标识符的种类（由其之前的 token 判断）
const UnresolvedKind = enum {
    /// 内置类型与值（`u8`、`bool`、`true`、`null`、`undefined`）：没有声明位置
    primitive,
    /// 切片、数组的 `len` 与 `ptr`：没有声明位置
    len_ptr,
    /// `error.Foo`：没有声明位置
    error_name,
    /// 没有左侧的 `.name`：枚举字面量、decl literal、初始化中的字段名
    dot_literal,
    /// `a.name`
    member,
    /// 标签（`break :blk`）
    label,
    /// 名字引用（局部、容器级、模块名）
    name,
};

fn classifyUnresolved(name: []const u8, before: [2]std.zig.Token.Tag) UnresolvedKind {
    if (std.zig.primitives.isPrimitive(name)) return .primitive;
    if (before[1] == .colon and (before[0] == .keyword_break or before[0] == .keyword_continue)) return .label;
    if (before[1] != .period) return .name;
    return switch (before[0]) {
        .keyword_error => .error_name,
        .identifier, .r_paren, .r_bracket, .r_brace, .question_mark, .period_asterisk, .string_literal => if (std.mem.eql(u8, name, "len") or std.mem.eql(u8, name, "ptr")) .len_ptr else .member,
        else => .dot_literal,
    };
}

const Loc = struct { uri: []const u8, line: u32, character: u32 };

fn locOf(v: json.Value) Loc {
    const start = v.object.get("range").?.object.get("start").?.object;
    return .{ .uri = v.object.get("uri").?.string, .line = @intCast(start.get("line").?.integer), .character = @intCast(start.get("character").?.integer) };
}

fn locEql(a: Loc, b: Loc) bool {
    return a.line == b.line and a.character == b.character and std.mem.eql(u8, a.uri, b.uri);
}

fn containsLoc(list: []const Loc, l: Loc) bool {
    for (list) |x| if (locEql(x, l)) return true;
    return false;
}

/// 查找引用与重命名的正确性（BENCH_REFS=<n>）：文件中均匀选 n 个声明（`const` / `var` / `fn` 之后的名字），
/// 1. 引用处的标识符与声明同名；2. 从每个引用处 declaration 回到该声明（无误报）；3. 本文件中 declaration
/// 指向该声明的同名标识符都在引用中（无漏报）；4. rename 的编辑与引用的位置相同
fn checkReferences(c: *Client, uri: []const u8, text: [:0]const u8, rel: []const u8, count: usize) !void {
    const a = c.arena.allocator();
    var decls: std.ArrayList(usize) = .empty;
    var tokenizer: std.zig.Tokenizer = .init(text);
    var prev: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof) break;
        if (t.tag == .identifier and (prev == .keyword_const or prev == .keyword_var or prev == .keyword_fn)) try decls.append(a, t.loc.start);
        prev = t.tag;
    }
    const n = @min(count, decls.items.len);
    var texts: std.StringHashMapUnmanaged([]const u8) = .empty;
    try texts.put(a, uri, text);
    var times: std.ArrayList(f64) = .empty;
    var total_refs: usize = 0;
    var bad_name: usize = 0;
    var false_pos: usize = 0;
    var missing: usize = 0;
    var rename_mismatch: usize = 0;
    var shown: usize = 0;
    var checked: usize = 0;
    for (0..n) |i| {
        const off = decls.items[i * decls.items.len / n];
        const name = identAt(text, off);
        const decl_pos = positionOf(text, off);
        const decl_loc: Loc = .{ .uri = uri, .line = decl_pos.line, .character = decl_pos.character };
        // 只取声明处（`[]const T` 中的 T 等不是声明）：declaration 指向自身
        {
            const self, _ = try c.request("textDocument/declaration", .{ .textDocument = .{ .uri = uri }, .position = decl_pos });
            const target = if (self.object.get("result")) |r| switch (r) {
                .object => locOf(r),
                .array => |arr| if (arr.items.len > 0) locOf(arr.items[0]) else null,
                else => null,
            } else null;
            if (target == null or !locEql(target.?, decl_loc)) continue;
        }
        checked += 1;
        const resp, const ms_refs = try c.request("textDocument/references", .{ .textDocument = .{ .uri = uri }, .position = decl_pos, .context = .{ .includeDeclaration = true } });
        try times.append(a, ms_refs);
        const result = resp.object.get("result") orelse continue;
        if (result != .array) continue;
        var refs: std.ArrayList(Loc) = .empty;
        for (result.array.items) |v| try refs.append(a, locOf(v));
        total_refs += refs.items.len;
        for (refs.items) |l| {
            const t = texts.get(l.uri) orelse blk: {
                const path = za.base.uri.toPath(a, l.uri) catch break :blk "";
                const x = Io.Dir.cwd().readFileAlloc(c.io, path, a, .limited(16 * 1024 * 1024)) catch "";
                try texts.put(a, l.uri, x);
                break :blk x;
            };
            const o2 = offsetOf(t, .{ .line = l.line, .character = l.character }) orelse continue;
            if (!std.mem.eql(u8, identAt(t, o2), name)) {
                bad_name += 1;
                continue;
            }
            // 引用所在的文件须先打开才能请求（其他文件按需打开再关闭）
            const other = !std.mem.eql(u8, l.uri, uri);
            if (other) try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = l.uri, .languageId = "zig", .version = 1, .text = t } });
            const back, _ = try c.request("textDocument/declaration", .{ .textDocument = .{ .uri = l.uri }, .position = .{ .line = l.line, .character = l.character } });
            if (other) try c.notify("textDocument/didClose", .{ .textDocument = .{ .uri = l.uri } });
            const target = if (back.object.get("result")) |r| switch (r) {
                .object => locOf(r),
                .array => |arr| if (arr.items.len > 0) locOf(arr.items[0]) else null,
                else => null,
            } else null;
            if (target == null or !locEql(target.?, decl_loc)) {
                false_pos += 1;
                if (shown < 10) {
                    shown += 1;
                    std.debug.print("    false positive `{s}` ({s}:{d}): {s}:{d}:{d}\n", .{ name, rel, decl_pos.line + 1, std.fs.path.basename(l.uri), l.line + 1, l.character + 1 });
                }
            }
        }
        // 本文件中同名、declaration 指向该声明的标识符
        var tk: std.zig.Tokenizer = .init(text);
        while (true) {
            const t = tk.next();
            if (t.tag == .eof) break;
            if (t.tag != .identifier or !std.mem.eql(u8, text[t.loc.start..t.loc.end], name)) continue;
            const p = positionOf(text, t.loc.start);
            const here: Loc = .{ .uri = uri, .line = p.line, .character = p.character };
            if (containsLoc(refs.items, here)) continue;
            const back, _ = try c.request("textDocument/declaration", .{ .textDocument = .{ .uri = uri }, .position = p });
            const target = if (back.object.get("result")) |r| switch (r) {
                .object => locOf(r),
                .array => |arr| if (arr.items.len > 0) locOf(arr.items[0]) else null,
                else => null,
            } else null;
            if (target != null and locEql(target.?, decl_loc) and !locEql(here, decl_loc)) {
                missing += 1;
                if (shown < 10) {
                    shown += 1;
                    std.debug.print("    missing `{s}` ({s}:{d}): {s}:{d}:{d}\n", .{ name, rel, decl_pos.line + 1, rel, p.line + 1, p.character + 1 });
                }
            }
        }
        // rename 的编辑与引用的位置相同
        const ren, _ = try c.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = decl_pos, .newName = "zz_renamed" });
        if (ren.object.get("result")) |r| if (r == .object) {
            var edits: std.ArrayList(Loc) = .empty;
            if (r.object.get("changes")) |changes| {
                var it = changes.object.iterator();
                while (it.next()) |kv| for (kv.value_ptr.array.items) |e| {
                    const st = e.object.get("range").?.object.get("start").?.object;
                    try edits.append(a, .{ .uri = kv.key_ptr.*, .line = @intCast(st.get("line").?.integer), .character = @intCast(st.get("character").?.integer) });
                };
            } else if (r.object.get("documentChanges")) |dcs| for (dcs.array.items) |dc| {
                const du = dc.object.get("textDocument").?.object.get("uri").?.string;
                for (dc.object.get("edits").?.array.items) |e| {
                    const st = e.object.get("range").?.object.get("start").?.object;
                    try edits.append(a, .{ .uri = du, .line = @intCast(st.get("line").?.integer), .character = @intCast(st.get("character").?.integer) });
                }
            };
            var same = edits.items.len == refs.items.len;
            if (same) for (edits.items) |e| if (!containsLoc(refs.items, e)) {
                same = false;
            };
            if (!same) {
                rename_mismatch += 1;
                if (shown < 10) {
                    shown += 1;
                    std.debug.print("    rename mismatch `{s}` ({s}:{d}): {d} edits, {d} references\n", .{ name, rel, decl_pos.line + 1, edits.items.len, refs.items.len });
                }
            }
        };
    }
    Stats.print("references", times.items);
    std.debug.print("  references   checked {d} declarations, {d} references: wrong name {d}, false positives {d}, missing in this file {d}, rename mismatches {d}\n", .{ checked, total_refs, bad_name, false_pos, missing, rename_mismatch });
}

/// 补全的召回（BENCH_COMPLETE=<n>）：源码中的成员访问 `a.b`（`.` 之前是标识符、`)` 或 `]`），在 `.` 之后
/// 请求补全，列表中应有 `b`。均匀取样 n 处，输出召回率与未补全的样例
fn checkCompletion(c: *Client, uri: []const u8, text: [:0]const u8, rel: []const u8, count: usize) !void {
    const a = c.arena.allocator();
    var sites: std.ArrayList(usize) = .empty;
    var tokenizer: std.zig.Tokenizer = .init(text);
    var prev2: std.zig.Token.Tag = .invalid;
    var prev: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof) break;
        if (t.tag == .identifier and prev == .period and (prev2 == .identifier or prev2 == .r_paren or prev2 == .r_bracket)) try sites.append(a, t.loc.start);
        prev2 = prev;
        prev = t.tag;
    }
    const n = @min(count, sites.items.len);
    var found: usize = 0;
    var empty: usize = 0;
    var shown: usize = 0;
    var times: std.ArrayList(f64) = .empty;
    for (0..n) |i| {
        const off = sites.items[i * sites.items.len / n];
        const name = identAt(text, off);
        const resp, const ms_c = try c.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = positionOf(text, off) });
        try times.append(a, ms_c);
        const result = resp.object.get("result") orelse continue;
        const items = switch (result) {
            .array => |arr| arr.items,
            .object => |o| o.get("items").?.array.items,
            else => &.{},
        };
        if (items.len == 0) empty += 1;
        const hit = for (items) |it| {
            const label = it.object.get("label").?.string;
            // `@"struct"` 形式的标签按其中的名字比较
            const bare = if (std.mem.startsWith(u8, label, "@\"") and label.len > 3) label[2 .. label.len - 1] else label;
            if (std.mem.eql(u8, bare, name)) break true;
        } else false;
        if (hit) {
            found += 1;
        } else if (shown < 15) {
            shown += 1;
            const p = positionOf(text, off);
            const line_start = off - p.character;
            const line_end = std.mem.indexOfScalarPos(u8, text, off, '\n') orelse text.len;
            std.debug.print("    not offered {s}:{d}:{d} `{s}` ({d} items) | {s}\n", .{ rel, p.line + 1, p.character + 1, name, items.len, std.mem.trim(u8, text[line_start..line_end], " ") });
        }
    }
    Stats.print("member compl.", times.items);
    std.debug.print("  completion   checked {d} member accesses: offered {d} ({d:.1}%), empty lists {d}\n", .{ n, found, @as(f64, @floatFromInt(found)) * 100 / @as(f64, @floatFromInt(@max(n, 1))), empty });
}

/// 长时间会话（BENCH_SESSION=<轮数>）：每轮在项目的 25 个文件（逐轮向后轮换）中打开、hover、补全、
/// 编辑并关闭，结束后打印堆、InternPool 与主要 query 的内存，观察长时间运行时内存的增长
fn longSession(c: *Client, root: []const u8, rounds: usize) !void {
    const a = c.arena.allocator();
    const io = c.io;
    const found = try std.process.run(c.gpa, io, .{ .argv = &.{ "find", root, "-name", "*.zig", "-not", "-path", "*/.zig-cache/*", "-not", "-path", "*/zig-out/*" } });
    defer c.gpa.free(found.stdout);
    defer c.gpa.free(found.stderr);
    var files: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, found.stdout, '\n');
    while (lines.next()) |l| try files.append(a, try a.dupe(u8, l));
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    if (files.items.len == 0) return;
    const per_round = 25;
    std.debug.print("long session: {d} rounds × {d} files (of {d})\n", .{ rounds, per_round, files.items.len });
    std.debug.print("  {s:>5} {s:>8} {s:>8} {s:>9} {s:>8} {s:>8} {s:>8} {s:>8} {s:>9} {s:>9} {s:>6}\n", .{ "round", "rss MB", "heap MB", "ip items", "ip MB", "infer MB", "body MB", "parse MB", "keys", "deps", "s" });
    const t0 = Io.Clock.awake.now(io);
    var version: i64 = 1;
    for (0..rounds) |round| {
        for (0..per_round) |k| {
            const path = files.items[(round * per_round + k) % files.items.len];
            const text = Io.Dir.cwd().readFileAllocOptions(io, path, a, .limited(8 * 1024 * 1024), .of(u8), 0) catch continue;
            const uri = try za.base.uri.fromPath(a, path);
            const doc = .{ .uri = uri };
            try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = version, .text = text } });
            version += 1;
            const idents = try samplePositions(a, text, false);
            const step = @max(1, idents.len / 10);
            var i: usize = 0;
            while (i < idents.len) : (i += step) _ = try c.request("textDocument/hover", .{ .textDocument = doc, .position = idents[i] });
            const dots = try samplePositions(a, text, true);
            if (dots.len > 0) _ = try c.request("textDocument/completion", .{ .textDocument = doc, .position = dots[dots.len / 2] });
            const end = positionOf(text, text.len);
            try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = end, .end = end }, .text = "// x" }} });
            version += 1;
            try c.notify("textDocument/didClose", .{ .textDocument = doc });
        }
        _ = try c.request("zig-analyzer/waitIdle", {});
        const st, _ = try c.request("zig-analyzer/status", {});
        const o = st.object.get("result").?.object;
        var infer_b: i64 = 0;
        var body_b: i64 = 0;
        var parse_b: i64 = 0;
        var keys: i64 = 0;
        var deps: i64 = 0;
        for (o.get("queries").?.array.items) |q| {
            keys += q.object.get("keys").?.integer;
            deps += q.object.get("deps").?.integer;
            const name = q.object.get("name").?.string;
            const b = q.object.get("bytes").?.integer;
            if (std.mem.endsWith(u8, name, ".Infer")) infer_b = b;
            if (std.mem.endsWith(u8, name, ".ItemBody")) body_b = b;
            if (std.mem.endsWith(u8, name, ".ParseFile")) parse_b = b;
        }
        const mb = struct {
            fn f(x: i64) f64 {
                return @as(f64, @floatFromInt(x)) / (1024 * 1024);
            }
        }.f;
        std.debug.print("  {d:>5} {d:>8.0} {d:>8.0} {d:>9} {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.1} {d:>9} {d:>9} {d:>6.0}\n", .{
            round + 1,
            (try rssMb(c.gpa, io, c.child.id.?)) orelse 0,
            mb(o.get("heap_bytes").?.integer),
            @as(u64, @intCast(o.get("intern_pool_items").?.integer)),
            mb(o.get("intern_pool_bytes").?.integer),
            mb(infer_b),
            mb(body_b),
            mb(parse_b),
            @as(u64, @intCast(keys)),
            @as(u64, @intCast(deps)),
            @as(f64, @floatFromInt(t0.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_s,
        });
        if (round + 1 == rounds) {
            // 最后一轮：按字节数列出各 query，其余为未归属（引擎的表、依赖、Vfs 等）
            const Row = struct { name: []const u8, bytes: i64, memos: i64, keys: i64 };
            var rows: std.ArrayList(Row) = .empty;
            var attributed: i64 = o.get("intern_pool_bytes").?.integer;
            for (o.get("queries").?.array.items) |q| {
                const b = q.object.get("bytes").?.integer;
                attributed += b;
                try rows.append(a, .{ .name = q.object.get("name").?.string, .bytes = b, .memos = q.object.get("memos").?.integer, .keys = q.object.get("keys").?.integer });
            }
            std.mem.sort(Row, rows.items, {}, struct {
                fn gt(_: void, x: Row, y: Row) bool {
                    return x.bytes > y.bytes;
                }
            }.gt);
            std.debug.print("  memory by query (last round):\n", .{});
            for (rows.items[0..@min(12, rows.items.len)]) |r| std.debug.print("    {s:<28} {d:>8.1} MB  memos {d:>7}  keys {d:>7}\n", .{ r.name, mb(r.bytes), r.memos, r.keys });
            std.debug.print("    {s:<28} {d:>8.1} MB\n", .{ "InternPool", mb(o.get("intern_pool_bytes").?.integer) });
            std.debug.print("    {s:<28} {d:>8.1} MB\n", .{ "unattributed", mb(o.get("heap_bytes").?.integer - attributed) });
        }
    }
}

/// 文件后半段第一个函数体中的语句（缩进至少 8 个空格、以 `;` 结尾）的行尾偏移
fn bodyLine(text: []const u8) ?usize {
    var start = std.mem.indexOfScalarPos(u8, text, text.len / 2, '\n') orelse return null;
    while (start < text.len) {
        const line_start = start + 1;
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse return null;
        const line = text[line_start..line_end];
        if (std.mem.startsWith(u8, line, "        ") and std.mem.endsWith(u8, line, ";") and std.mem.indexOf(u8, line, "//") == null) return line_end;
        start = line_end;
    }
    return null;
}

fn above(n: usize, base: usize) bool {
    return n > base;
}

fn atBase(n: usize, base: usize) bool {
    return n <= base;
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
        if (verbose) try c.phase("open + project load");
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
            if (verbose) try c.phase(method);
            if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("  {s:<12} memory {d:.0} MB\n", .{ "", mb });
            std.debug.print("  {s:<12} non-null {d}/{d}\n", .{ "", hits, positions.len });
            std.debug.print("  {s:<12} first pass max {d:.1}ms\n", .{ "", cold_max });
        }

        if (init.environ_map.get("BENCH_COMPLETE")) |v| try checkCompletion(&c, uri, text, rel, std.fmt.parseInt(usize, v, 10) catch 300);
        if (init.environ_map.get("BENCH_REFS")) |v| try checkReferences(&c, uri, text, rel, std.fmt.parseInt(usize, v, 10) catch 20);
        if (init.environ_map.get("BENCH_CHECK")) |v| {
            c.unresolved_samples = std.fmt.parseInt(usize, v, 10) catch 0;
            try checkDeclarations(&c, uri, text, rel);
        }

        // 编辑 → live 诊断：在文件末尾加入语法错误，再撤销（BENCH_QUICK 时跳过编辑相关的各阶段）
        if (init.environ_map.get("BENCH_QUICK") == null) {
            const end = positionOf(text, text.len);
            var edit_times: [10]f64 = undefined;
            var clear_times: [10]f64 = undefined;
            var version: i64 = 2;
            const base = try c.baseErrors(uri);
            for (&edit_times, &clear_times) |*te, *tc| {
                var t0 = Io.Clock.awake.now(io);
                try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = end, .end = end }, .text = "@@" }} });
                version += 1;
                te.* = try c.waitDiagnostics(uri, t0, above, base);
                t0 = Io.Clock.awake.now(io);
                const after: Position = .{ .line = end.line, .character = end.character + 2 };
                try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = end, .end = after }, .text = "" }} });
                version += 1;
                tc.* = try c.waitDiagnostics(uri, t0, atBase, base);
            }
            Stats.print("edit→diag", &edit_times);
            Stats.print("undo→clear", &clear_times);

            // 连续输入：在文件末尾的注释中每 30ms 输入一个字符，每次按键后立即 hover。编辑的写事务要等
            // 进行中的读事务（诊断计算）退出，这里的延迟包含这段等待
            {
                try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = end, .end = end }, .text = "//" }} });
                version += 1;
                _ = try c.request("zig-analyzer/waitIdle", {});
                var typing_times: [40]f64 = undefined;
                for (&typing_times, 0..) |*t, i| {
                    const at: Position = .{ .line = end.line, .character = end.character + 2 + @as(u32, @intCast(i)) };
                    try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = at, .end = at }, .text = "x" }} });
                    version += 1;
                    _, t.* = try c.request("textDocument/hover", .{ .textDocument = doc, .position = idents[i % idents.len] });
                    try (Io.Clock.Duration{ .raw = .fromMilliseconds(30), .clock = .awake }).sleep(io);
                }
                Stats.print("type→hover", &typing_times);
                const typed_end: Position = .{ .line = end.line, .character = end.character + 2 + @as(u32, typing_times.len) };
                try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = end, .end = typed_end }, .text = "" }} });
                version += 1;
            }

            // 函数体中的编辑（实际编辑的常见位置，走块级增量重解析）：文件后半段第一个缩进至少 8 个空格、
            // 以 `;` 结尾的语句，在行尾加入语法错误再撤销；再在行尾的注释中连续输入并 hover
            if (bodyLine(text)) |line_end| {
                const body_base = try c.baseErrors(uri);
                if (verbose) try c.phase("end-of-file edits");
                const at = positionOf(text, line_end);
                const after: Position = .{ .line = at.line, .character = at.character + 2 };
                var body_edit_times: [10]f64 = undefined;
                var body_clear_times: [10]f64 = undefined;
                for (&body_edit_times, &body_clear_times) |*te, *tc| {
                    var t0 = Io.Clock.awake.now(io);
                    try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = at, .end = at }, .text = "@@" }} });
                    version += 1;
                    te.* = try c.waitDiagnostics(uri, t0, above, body_base);
                    t0 = Io.Clock.awake.now(io);
                    try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = at, .end = after }, .text = "" }} });
                    version += 1;
                    tc.* = try c.waitDiagnostics(uri, t0, atBase, body_base);
                }
                Stats.print("body edit→diag", &body_edit_times);
                Stats.print("body undo→clear", &body_clear_times);
                try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = at, .end = at }, .text = " //" }} });
                version += 1;
                _ = try c.request("zig-analyzer/waitIdle", {});
                var body_typing_times: [40]f64 = undefined;
                for (&body_typing_times, 0..) |*t, i| {
                    const p: Position = .{ .line = at.line, .character = at.character + 3 + @as(u32, @intCast(i)) };
                    try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = p, .end = p }, .text = "x" }} });
                    version += 1;
                    _, t.* = try c.request("textDocument/hover", .{ .textDocument = doc, .position = idents[i % idents.len] });
                    try (Io.Clock.Duration{ .raw = .fromMilliseconds(30), .clock = .awake }).sleep(io);
                }
                Stats.print("body type→hover", &body_typing_times);
                const body_typed_end: Position = .{ .line = at.line, .character = at.character + 3 + @as(u32, body_typing_times.len) };
                try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = at, .end = body_typed_end }, .text = "" }} });
                version += 1;
            }
            if (verbose) {
                _ = try c.request("zig-analyzer/waitIdle", {});
                try c.phase("in-body edits (incl. background work until idle)");
            }

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
    if (init.environ_map.get("BENCH_SESSION")) |v| try longSession(&c, root, try std.fmt.parseInt(usize, v, 10));
    if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("resident memory {d:.0} MB\n", .{mb});
    try printQueryTable(&c);
    _ = try c.request("shutdown", {});
    try c.send(.{ .jsonrpc = "2.0", .method = "exit" });
    _ = try c.child.wait(io);
    return 0;
}
