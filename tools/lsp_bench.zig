//! LSP benchmark (the performance goals in docs/perf.md): starts zig-analyzer as a child
//! process and talks to it over stdin/stdout the way a real editor does, measuring the phases of
//! a cold start, the latency distribution of hover / goto / completion in a warm state, the
//! latency from an edit to diagnostics, and resident memory.
//!
//! Usage: zig build bench -Doptimize=ReleaseSafe -- <project root> <file (relative to the root)>...
//!
//! Request positions are sampled evenly over the identifiers of a file (at most `samples` per
//! file); completion uses the position after a `.`.
//!
//! The exit code is 1 when a check enabled below fails its pass criterion in docs/perf.md, or
//! when the server's semantic token deltas do not add up to its full result. Latency targets are
//! marked `met` / `MISSED` in the output and do not affect the exit code: they apply to the
//! benchmark project, and missing them on a very large file is a known gap.
//!
//! Environment variables:
//! - `BENCH_CONFIG`: the configuration (JSON) to answer `workspace/configuration` with, e.g.
//!   `{"build":{"args":["-Dno-bin"]}}`
//! - `BENCH_SAVE=1`: measure save → build finished, and compare the published errors with the
//!   output of `zig build` for the same step and arguments (see `compareWithBuild`; rewrites files
//!   in the project and restores them at the end)
//! - `BENCH_HOVER=line:col`: print the hover result at that position
//! - `BENCH_VERBOSE=1`: print the slow requests of the first pass, their memory change, and the
//!   execution count of each query
//! - `BENCH_CHECK=<n>`: check goto correctness: request declaration for the identifiers in the
//!   file; the identifier at the target must be the same as at the request position; also print
//!   the first n unresolved identifiers
//! - `BENCH_TYPE_COMPLETE=<n>`: in each of n name expressions, insert a character, immediately
//!   request completion, then undo; the timing includes the edit and the completion, and the
//!   number of auto-import candidates and the changes in index queries are reported (auto-import
//!   is on by default; disable it with `BENCH_CONFIG='{"completion":{"auto_import":false}}'` to
//!   compare the cost with it on)
//! - `BENCH_QUICK=1`: skip the edit, continuous typing, and save phases (used when checking many
//!   projects in bulk)
//! - `BENCH_TYPE_WORDS=<line>:<word>,<word>...`: type each word character by character in a new
//!   statement after line `line`, requesting completion after each character (see `typeWords`)
//! - `BENCH_TYPE_STMT=<statement>`: the statement `BENCH_TYPE_WORDS` inserts, with `|` marking
//!   where to type (default `_ = |;`); e.g. `const probe: Air.Inst.Ref = |;` types where there is
//!   an expected type
//! - `BENCH_COMPLETE=<n>`: completion recall: for each member access `a.b` in the source,
//!   complete after the `.`; the list must contain `b`
//! - `BENCH_REFS=<n>`: check find references and rename for n declarations (same name, no false
//!   positives, nothing missed in this file, rename consistent with references; references in a
//!   generic function body that point to a same-named declaration under another instance are
//!   counted separately)
//! - `BENCH_SESSION=<rounds>`: a long session, to watch memory growth
//! - `BENCH_CONCURRENT=<n>`: throughput: open the n largest files of the project at once and
//!   request their semantic tokens without waiting for the answers (see `concurrentTokens`)
//! - `BENCH_INSTANCE_HOVER=<n>`: hover at n names after `.` in the bodies of generic functions,
//!   where a name can refer to a different declaration under each instance (see
//!   `instanceHover`); the files on the command line only load the project, and the phases
//!   above do not run. `BENCH_INSTANCE_HOVER_DIRS=<dir>,...` samples only the files under these
//!   directories (relative to the project root); `BENCH_INSTANCE_HOVER_OUT=<path>` writes the
//!   result at each name, tab-separated, to compare builds name by name;
//!   `BENCH_INSTANCE_HOVER_TOKENS=1` requests semantic tokens for each file before its hovers
//!   (with `BENCH_INSTANCE_HOVER_OUT`, their time per file goes to `<path>.tokens`)

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const za = @import("zig_analyzer");
const transport = za.lsp.transport;

const samples = 200;
/// Positions per method answered right after opening the first file, compared with the answers
/// once the project is loaded
const early_samples = 20;
/// Server processes started to sample the latency of `initialize`
const initialize_samples = 5;
/// `diagnostics.debounce_ms` when `BENCH_CONFIG` does not set it
const default_debounce_ms = 50;
/// Delay before the server reports the progress of indexing (`index_progress_delay_ms`)
const index_progress_delay_ms = 200;
/// Prints the requests of the first pass that take more than 20ms, with their memory change
/// (BENCH_VERBOSE=1)
var verbose = false;
/// Checks that failed their pass criterion: makes the exit code 1
var failures: usize = 0;
var targets_missed: usize = 0;

fn checkFailed(comptime fmt: []const u8, args: anytype) void {
    failures += 1;
    std.debug.print("  FAILED: " ++ fmt ++ "\n", args);
}

/// Prints a latency against its target in docs/perf.md
fn reportTarget(name: []const u8, value: f64, limit: f64) void {
    const met = value < limit;
    if (!met) targets_missed += 1;
    std.debug.print("  target       {s}: {d:.1}ms (< {d:.0}ms) {s}\n", .{ name, value, limit, if (met) "met" else "MISSED" });
}

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
    /// Configuration to answer `workspace/configuration` with (BENCH_CONFIG, JSON)
    config: json.Value = .null,
    /// Number of build progress operations that have ended (title starting with `zig build`)
    builds_done: usize = 0,
    build_tokens: std.ArrayList([]const u8) = .empty,
    /// Message at the end of the most recent build (e.g. `1 error(s)`)
    build_message: []const u8 = "",
    /// Title of the most recent build (`zig build <steps>`)
    build_title: []const u8 = "",
    load_tokens: std.ArrayList([]const u8) = .empty,
    /// Number of project loads that have ended; answers before the first are given without a project
    loads_ended: usize = 0,
    index_token: ?[]const u8 = null,
    index_begin: Io.Timestamp = undefined,
    /// Time from the start of the symbol index's progress to its end; null when the server
    /// reported none
    index_ms: ?f64 = null,
    /// Diagnostics last published for each file (by uri)
    published: std.StringArrayHashMapUnmanaged([]const json.Value) = .empty,
    /// Number of error diagnostics last published for each file (by uri)
    errors: std.StringHashMapUnmanaged(usize) = .empty,
    last_counts: []const QueryCount = &.{},
    /// Number of unresolved samples printed by the goto check (the value of BENCH_CHECK)
    unresolved_samples: usize = 0,

    fn spawn(c: *Client, exe: []const u8) !void {
        c.child = try std.process.spawn(c.io, .{ .argv = &.{exe}, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
        c.reader = c.child.stdout.?.readerStreaming(c.io, &c.read_buffer);
        c.writer = c.child.stdin.?.writerStreaming(c.io, &c.write_buffer);
    }

    fn initialize(c: *Client, root_uri: []const u8) !json.Value {
        // Sample positions and the columns in the checks are byte offsets: positions must be counted in
        // UTF-8, otherwise they are off on lines with multibyte characters
        const resp, _ = try c.request("initialize", .{
            .rootUri = root_uri,
            .capabilities = .{
                .general = .{ .positionEncodings = &[_][]const u8{"utf-8"} },
                .workspace = .{ .configuration = true },
                .window = .{ .workDoneProgress = true },
                // Like common editors, completion uses snippets (turn them off with
                // `BENCH_CONFIG='{"completion":{"snippets":false}}'`)
                .textDocument = .{ .completion = .{ .completionItem = .{ .snippetSupport = true } } },
            },
        });
        return resp;
    }

    /// A value of the configuration in `BENCH_CONFIG`
    fn configValue(c: *const Client, section: []const u8, key: []const u8) ?json.Value {
        if (c.config != .object) return null;
        const s = c.config.object.get(section) orelse return null;
        return if (s == .object) s.object.get(key) else null;
    }

    fn send(c: *Client, value: anytype) !void {
        const body = try json.Stringify.valueAlloc(c.gpa, value, .{ .emit_null_optional_fields = false });
        defer c.gpa.free(body);
        const w = &c.writer.interface;
        try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try w.writeAll(body);
        try w.flush();
    }

    /// Increase in the execution count and total time of each query since the previous phase
    /// (BENCH_VERBOSE)
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

    /// Reads the next message; requests from the server are answered right away (an empty
    /// configuration, null for everything else)
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
                try c.published.put(c.arena.allocator(), entry.key_ptr.*, params.get("diagnostics").?.array.items);
            }
            // Progress events: print a timeline
            if (std.mem.eql(u8, method.string, "$/progress")) {
                const v = msg.object.get("params").?.object.get("value").?.object;
                const kind = v.get("kind").?.string;
                if (!std.mem.eql(u8, kind, "report")) {
                    const title = if (v.get("title")) |t| t.string else if (v.get("message")) |m| m.string else "";
                    if (verbose or c.builds_done == 0) std.debug.print("    [{d:>8.0}ms] progress {s} {s}\n", .{ ms(c.io, c.start), kind, title });
                    const token = try json.Stringify.valueAlloc(c.arena.allocator(), msg.object.get("params").?.object.get("token").?, .{});
                    if (std.mem.eql(u8, kind, "begin") and std.mem.startsWith(u8, title, "zig build")) {
                        try c.build_tokens.append(c.arena.allocator(), token);
                        c.build_title = try c.arena.allocator().dupe(u8, title);
                    }
                    if (std.mem.eql(u8, kind, "begin") and std.mem.startsWith(u8, title, "Loading project")) {
                        try c.load_tokens.append(c.arena.allocator(), token);
                    }
                    if (std.mem.eql(u8, kind, "begin") and std.mem.eql(u8, title, "Indexing")) {
                        c.index_token = token;
                        c.index_begin = Io.Clock.awake.now(c.io);
                    }
                    if (std.mem.eql(u8, kind, "end")) {
                        for (c.load_tokens.items) |t| if (std.mem.eql(u8, t, token)) {
                            c.loads_ended += 1;
                        };
                        if (c.index_token) |t| if (std.mem.eql(u8, t, token)) {
                            c.index_ms = ms(c.io, c.index_begin);
                            c.index_token = null;
                        };
                    }
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

    /// Sends a request and waits for its response; returns the response and the elapsed time (ms)
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

    /// Waits until the number of error diagnostics of `uri` satisfies `pred`; returns the elapsed
    /// time (other severities, such as the hints for inactive code, do not count)
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

    /// Current number of error diagnostics of `uri`: waits for background work to finish first, so
    /// that the count is the result for the current text.
    /// Files such as the standard library may contain errors themselves; edit timings use this as
    /// the baseline
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

/// Positions sampled evenly over identifiers; with `after_dot`, the position after `.` in `a.b`
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

/// Samples for completion while typing: an identifier of length at least 3 whose previous
/// token is not `.`. Returns the insert position (the second byte of the name) and the position
/// to request completion at (the third byte of the name), so the edit and the completion both
/// fall within the same name expression.
const TypingPosition = struct { edit: Position, complete: Position };

fn typingPositions(a: Allocator, text: [:0]const u8) ![]TypingPosition {
    var all: std.ArrayList(TypingPosition) = .empty;
    var tokenizer: std.zig.Tokenizer = .init(text);
    var prev: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof) break;
        if (t.tag == .identifier and prev != .period and t.loc.end - t.loc.start >= 3 and text[t.loc.start] != '@') {
            try all.append(a, .{
                .edit = positionOf(text, t.loc.start + 1),
                .complete = positionOf(text, t.loc.start + 2),
            });
        }
        prev = t.tag;
    }
    return all.items;
}

/// Whether a completion response has auto-import items: items with additional edits or a qualified
/// name (`labelDetails`). Function items also carry data, so data cannot be used to decide
fn hasAutoImport(response: std.json.Value) bool {
    const items = completionItems(response);
    for (items) |item| {
        if (item != .object) continue;
        if (item.object.get("additionalTextEdits") != null or item.object.get("labelDetails") != null) return true;
    }
    return false;
}

fn completionItems(response: std.json.Value) []const std.json.Value {
    const result = response.object.get("result") orelse return &.{};
    return switch (result) {
        .array => |array| array.items,
        .object => |object| if (object.get("items")) |items| items.array.items else &.{},
        else => &.{},
    };
}

/// Typing words (BENCH_TYPE_WORDS=<line>:<word>,<word>...): inserts the statement `template` after
/// line `line` (`|` marks where to type) and types each word character by character at the `|`,
/// requesting completion right after each character, then deletes the word. Waits for background
/// work to finish before each keystroke, so the timing covers only that keystroke's edit and
/// completion. Reports the latency of the first keystroke (which includes building the index and
/// the inference for the first time) and of the later ones, and for each completion the number of
/// candidates and how many of them are member paths of local values (fields and methods whose
/// labels contain `.`)
fn typeWords(c: *Client, uri: []const u8, text: []const u8, spec: []const u8, template: []const u8, version: *i64) !void {
    const a = c.arena.allocator();
    const io = c.io;
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return error.BadTypeWordsSpec;
    const line = try std.fmt.parseInt(u32, spec[0..colon], 10);
    var line_start: usize = 0;
    for (1..line) |_| line_start = (std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse return error.BadTypeWordsSpec) + 1;
    const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
    const at = positionOf(text, line_end);
    const doc = .{ .uri = uri };
    const marker = std.mem.indexOfScalar(u8, template, '|') orelse return error.BadTypeStatement;
    const indent = "\n    ";
    const statement = try std.mem.concat(a, u8, &.{ indent, template[0..marker], template[marker + 1 ..] });
    try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version.* }, .contentChanges = &.{.{ .range = .{ .start = at, .end = at }, .text = statement }} });
    version.* += 1;
    _ = try c.request("zig-analyzer/waitIdle", {});
    const start: Position = .{ .line = at.line + 1, .character = @intCast(indent.len - 1 + marker) };
    std.debug.print("  type words after line {d}: `{s}`, in `{s}`\n", .{ line, lineText(text, line - 1), template });
    var times: std.ArrayList(f64) = .empty;
    var first: ?f64 = null;
    var items_total: usize = 0;
    var paths_total: usize = 0;
    var paths_max: usize = 0;
    var words = std.mem.splitScalar(u8, spec[colon + 1 ..], ',');
    while (words.next()) |word| {
        for (word, 0..) |ch, i| {
            const p: Position = .{ .line = start.line, .character = start.character + @as(u32, @intCast(i)) };
            // Wait for the background work triggered by the previous keystroke (diagnostics and so
            // on) to finish, so the timing covers only this edit and completion
            _ = try c.request("zig-analyzer/waitIdle", {});
            const t0 = Io.Clock.awake.now(io);
            try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version.* }, .contentChanges = &.{.{ .range = .{ .start = p, .end = p }, .text = &[_]u8{ch} }} });
            version.* += 1;
            const resp, _ = try c.request("textDocument/completion", .{ .textDocument = doc, .position = Position{ .line = p.line, .character = p.character + 1 } });
            const t = ms(io, t0);
            if (first == null) first = t else try times.append(a, t);
            const items = completionItems(resp);
            var paths: usize = 0;
            for (items) |it| {
                const kind = if (it.object.get("kind")) |k| k.integer else 0;
                // LSP CompletionItemKind: Method = 2, Field = 5
                if ((kind == 2 or kind == 5) and std.mem.indexOfScalar(u8, it.object.get("label").?.string, '.') != null) paths += 1;
            }
            items_total += items.len;
            paths_total += paths;
            paths_max = @max(paths_max, paths);
            if (verbose) std.debug.print("    `{s}` {d:.1}ms {d} items, {d} member paths, first `{s}`\n", .{ word[0 .. i + 1], t, items.len, paths, firstRanked(items) });
        }
        const end: Position = .{ .line = start.line, .character = start.character + @as(u32, @intCast(word.len)) };
        try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version.* }, .contentChanges = &.{.{ .range = .{ .start = start, .end = end }, .text = "" }} });
        version.* += 1;
    }
    const keys = times.items.len + 1;
    std.debug.print("  type words   first keystroke {d:.1}ms\n", .{first orelse 0});
    Stats.print("type words", times.items);
    std.debug.print("  type words   {d} keystrokes: {d:.0} items on average, member paths {d:.0} on average, at most {d}\n", .{ keys, @as(f64, @floatFromInt(items_total)) / @as(f64, @floatFromInt(keys)), @as(f64, @floatFromInt(paths_total)) / @as(f64, @floatFromInt(keys)), paths_max });
    const after: Position = .{ .line = at.line + 1, .character = @intCast(statement.len - 1) };
    try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version.* }, .contentChanges = &.{.{ .range = .{ .start = at, .end = after }, .text = "" }} });
    version.* += 1;
}

/// The label of the top-ranked completion item (the smallest `sortText`)
fn firstRanked(items: []const json.Value) []const u8 {
    var best: ?json.Value = null;
    for (items) |it| {
        const sort = (it.object.get("sortText") orelse continue).string;
        if (best == null or std.mem.lessThan(u8, sort, best.?.object.get("sortText").?.string)) best = it;
    }
    return if (best) |b| b.object.get("label").?.string else "";
}

const Stats = struct {
    fn print(name: []const u8, times: []f64) void {
        if (times.len == 0) return;
        std.mem.sort(f64, times, {}, std.sort.asc(f64));
        std.debug.print("  {s:<12} n={d:<4} p50 {d:>7.1}ms  p95 {d:>7.1}ms  max {d:>7.1}ms\n", .{ name, times.len, at(times, 0.5), at(times, 0.95), times[times.len - 1] });
    }

    /// Quantile of times sorted by `print`
    fn at(t: []const f64, q: f64) f64 {
        return t[@min(t.len - 1, @as(usize, @intFromFloat(q * @as(f64, @floatFromInt(t.len)))))];
    }
};

const QueryCount = struct { name: []const u8, n: i64, ms: f64 = 0 };

/// Cumulative execution count of each query (zig-analyzer/status)
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

/// Time spent in each query over the whole server run (zig-analyzer/status), sorted by self time
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

/// Resident memory of the process in MB, or null when it cannot be read: `ps` cannot run or its
/// output does not parse (on Windows, the working set query fails). Callers print a missing
/// reading as unknown or leave it out.
fn rssMb(gpa: Allocator, io: Io, pid: std.process.Child.Id) !?f64 {
    // On Windows, Child.Id is a process HANDLE and there is no ps: read the working set of the
    // process directly
    if (@import("builtin").os.tag == .windows) {
        const w = std.os.windows;
        var c: w.PROCESS.VM_COUNTERS = undefined;
        if (w.ntdll.NtQueryInformationProcess(pid, .VmCounters, &c, @sizeOf(w.PROCESS.VM_COUNTERS), null) != .SUCCESS) return null;
        return @as(f64, @floatFromInt(c.WorkingSetSize)) / (1024 * 1024);
    }
    const pid_str = try std.fmt.allocPrint(gpa, "{d}", .{pid});
    defer gpa.free(pid_str);
    const r = std.process.run(gpa, io, .{ .argv = &.{ "ps", "-o", "rss=", "-p", pid_str } }) catch return null;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const kb = std.fmt.parseInt(u64, std.mem.trim(u8, r.stdout, " \n"), 10) catch return null;
    return @as(f64, @floatFromInt(kb)) / 1024;
}

/// A memory reading of `rssMb` followed by `unit`, or `unknown` when the reading is missing
fn mbText(a: Allocator, mb: ?f64, comptime unit: []const u8) ![]const u8 {
    return if (mb) |v| std.fmt.allocPrint(a, "{d:.0}" ++ unit, .{v}) else "unknown";
}

/// The memory change between two readings of `rssMb`, or `unknown` when either one is missing
fn memoryChangeText(a: Allocator, before: ?f64, after: ?f64) ![]const u8 {
    const from = before orelse return "unknown";
    const to = after orelse return "unknown";
    return std.fmt.allocPrint(a, "{d:.0} → {d:.0} MB", .{ from, to });
}

/// Resident memory in transparent huge pages (`AnonHugePages` of /proc/<pid>/smaps_rollup; Linux)
fn hugePagesMb(gpa: Allocator, io: Io, pid: std.process.Child.Id) ?f64 {
    if (@import("builtin").os.tag != .linux) return null;
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/smaps_rollup", .{pid}) catch return null;
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return null;
    defer gpa.free(text);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "AnonHugePages:")) continue;
        var it = std.mem.tokenizeScalar(u8, l["AnonHugePages:".len..], ' ');
        const kb = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        return @as(f64, @floatFromInt(kb)) / 1024;
    }
    return null;
}

/// Windows: private committed memory, its peak, and the peak working set of the process (MB)
fn commitMb(pid: std.process.Child.Id) ?[3]f64 {
    if (@import("builtin").os.tag != .windows) return null;
    const w = std.os.windows;
    var c: w.PROCESS.VM_COUNTERS = undefined;
    if (w.ntdll.NtQueryInformationProcess(pid, .VmCounters, &c, @sizeOf(w.PROCESS.VM_COUNTERS), null) != .SUCCESS) return null;
    const mb = 1024 * 1024;
    return .{ @as(f64, @floatFromInt(c.PagefileUsage)) / mb, @as(f64, @floatFromInt(c.PeakPagefileUsage)) / mb, @as(f64, @floatFromInt(c.PeakWorkingSetSize)) / mb };
}

/// The project's .zig files, sorted, outside `.zig-cache` and `zig-out`. The directory is walked
/// rather than searched with `find`, which on Windows is an unrelated program
fn projectFiles(c: *Client, root: []const u8) ![]const []const u8 {
    const a = c.arena.allocator();
    const io = c.io;
    var files: std.ArrayList([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(c.gpa);
    defer walker.deinit();
    while (try walker.next(io)) |e| switch (e.kind) {
        .directory => if (!std.mem.eql(u8, e.basename, ".zig-cache") and !std.mem.eql(u8, e.basename, "zig-out")) try walker.enter(io, e),
        .file => if (std.mem.endsWith(u8, e.basename, ".zig")) try files.append(a, try std.fs.path.join(a, &.{ root, e.path })),
        else => {},
    };
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return files.items;
}

/// MB of an integer field of the `allocator` object of `zig-analyzer/status` (0 without it)
/// Shares of the pages in each occupancy bin of `zig-analyzer/status`, in percent, separated by `/`
fn occupancyText(a: Allocator, v: ?json.Value) ![]const u8 {
    const items = (v orelse return "").array.items;
    var total: i64 = 0;
    for (items) |x| total += x.integer;
    if (total == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |x, i| {
        if (i != 0) try out.append(a, '/');
        try out.print(a, "{d}", .{@divTrunc(x.integer * 100 + @divTrunc(total, 2), total)});
    }
    return out.items;
}

fn allocatorMb(al: ?json.ObjectMap, key: []const u8) f64 {
    const v = (al orelse return 0).get(key) orelse return 0;
    return @as(f64, @floatFromInt(v.integer)) / (1024 * 1024);
}

/// Byte offset of a position (line and UTF-16 column; equal to the byte column when the sample
/// files are all ASCII)
fn offsetOf(text: []const u8, p: Position) ?usize {
    var line: u32 = 0;
    var start: usize = 0;
    while (line < p.line) : (line += 1) start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null) + 1;
    return if (start + p.character <= text.len) start + p.character else null;
}

/// Identifier at an offset (including the `@"..."` form)
fn identAt(text: []const u8, offset: usize) []const u8 {
    if (std.mem.startsWith(u8, text[offset..], "@\"")) {
        const end = std.mem.indexOfScalarPos(u8, text, offset + 2, '"') orelse return "";
        return text[offset + 2 .. end];
    }
    var end = offset;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    return text[offset..end];
}

/// Goto correctness (BENCH_CHECK=1): requests `textDocument/declaration` for each identifier in
/// the file (at most `limit`, sampled evenly); the identifier at the target must be the same as
/// at the request position (declaration does not follow alias chains)
fn checkDeclarations(c: *Client, uri: []const u8, text: [:0]const u8, rel: []const u8) !void {
    const a = c.arena.allocator();
    const limit = 3000;
    var offsets: std.ArrayList(usize) = .empty;
    // The two tokens before each identifier, used to classify unresolved identifiers
    var befores: std.ArrayList([2]std.zig.Token.Tag) = .empty;
    var tokenizer: std.zig.Tokenizer = .init(text);
    var prev: [2]std.zig.Token.Tag = .{ .invalid, .invalid };
    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof) break;
        // The `c` in `[*c]` is part of the pointer syntax, not a name
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
    // When a member name of a constructed type (`@Struct` etc.) cannot be traced to its origin in
    // the source, goto lands on the construction call: the member is created there, so it does not
    // count as a wrong jump
    var at_construction: usize = 0;
    var samples_shown: usize = 0;
    var unresolved_shown: usize = 0;
    // BENCH_CHECK=<n>: print the first n unresolved identifiers
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
            kinds[@backingInt(classifyUnresolved(name, before))] += 1;
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
        const constructions = [_][]const u8{ "@Struct(", "@Enum(", "@Union(" };
        if (for (constructions) |prefix| {
            if (std.mem.startsWith(u8, target_text[target_off..], prefix)) break true;
        } else false) {
            at_construction += 1;
            continue;
        }
        mismatched += 1;
        if (samples_shown < 12) {
            samples_shown += 1;
            const p = positionOf(text, off);
            const tp = positionOf(target_text, target_off);
            std.debug.print("    mismatch {s}:{d}:{d} `{s}` -> {s}:{d}:{d} `{s}`\n", .{ rel, p.line + 1, p.character + 1, name, std.fs.path.basename(target_uri), tp.line + 1, tp.character + 1, target_name });
        }
    }
    std.debug.print("  declaration  checked {d} identifiers: resolved {d} ({d:.1}%), mismatched {d}, at construction {d}\n", .{ n, resolved, @as(f64, @floatFromInt(resolved)) * 100 / @as(f64, @floatFromInt(@max(n, 1))), mismatched, at_construction });
    std.debug.print("  declaration  unresolved by kind:", .{});
    for (kinds, 0..) |k, i| std.debug.print(" {t} {d}", .{ @as(UnresolvedKind, @fromBackingInt(@intCast(i))), k });
    if (mismatched > 0) checkFailed("{d} goto targets have a different name in {s}", .{ mismatched, rel });
    // Built-in types and values, len / ptr, and error.X have no declaration position to begin with,
    // so they are excluded from the denominator
    const no_decl = kinds[@backingInt(UnresolvedKind.primitive)] + kinds[@backingInt(UnresolvedKind.len_ptr)] + kinds[@backingInt(UnresolvedKind.error_name)];
    std.debug.print("; resolved excluding identifiers without a declaration {d:.1}%\n", .{@as(f64, @floatFromInt(resolved)) * 100 / @as(f64, @floatFromInt(@max(n - no_decl, 1)))});
}

/// Kind of an unresolved identifier (determined from the tokens before it)
const UnresolvedKind = enum {
    /// Built-in types and values (`u8`, `bool`, `true`, `null`, `undefined`):
    /// no declaration position
    primitive,
    /// `len` and `ptr` of slices and arrays: no declaration position
    len_ptr,
    /// `error.Foo`: no declaration position
    error_name,
    /// `.name` without a left-hand side: enum literals, decl literals, field names in initializers
    dot_literal,
    /// `a.name`
    member,
    /// Labels (`break :blk`)
    label,
    /// Name references (locals, container-level names, module names)
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

/// Correctness of find references and rename (BENCH_REFS=<n>): picks n declarations evenly from the
/// file (the names after `const` / `var` / `fn`): 1. the identifier at each reference has the same
/// name as the declaration; 2. declaration from each reference leads back to that declaration (no
/// false positives); 3. every same-named identifier in this file whose declaration points to that
/// declaration is among the references (nothing missed); 4. the edits of rename are at the same
/// positions as the references
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
    var other_instance: usize = 0;
    var shown: usize = 0;
    var checked: usize = 0;
    for (0..n) |i| {
        const off = decls.items[i * decls.items.len / n];
        const name = identAt(text, off);
        const decl_pos = positionOf(text, off);
        const decl_loc: Loc = .{ .uri = uri, .line = decl_pos.line, .character = decl_pos.character };
        // Take only declaration sites (the T in `[]const T` and the like are not declarations):
        // declaration points to the name itself
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
        // When a reference in a generic function body points to different declarations under
        // different instances, rename returns an error; declaration at such a reference takes only
        // one instance and may point to another declaration with the same name (counted as other
        // instance, not a false positive)
        const ren, _ = try c.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = decl_pos, .newName = "zz_renamed" });
        const ambiguous = ren.object.get("error") != null;
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
            // The file containing a reference must be opened before requesting (other files are
            // opened on demand and closed afterwards)
            const other = !std.mem.eql(u8, l.uri, uri);
            if (other) try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = l.uri, .languageId = "zig", .version = 1, .text = t } });
            const back, _ = try c.request("textDocument/declaration", .{ .textDocument = .{ .uri = l.uri }, .position = .{ .line = l.line, .character = l.character } });
            if (other) try c.notify("textDocument/didClose", .{ .textDocument = .{ .uri = l.uri } });
            const target = if (back.object.get("result")) |r| switch (r) {
                .object => locOf(r),
                .array => |arr| if (arr.items.len > 0) locOf(arr.items[0]) else null,
                else => null,
            } else null;
            if (ambiguous) if (target) |tl| if (!locEql(tl, decl_loc)) {
                const tt = texts.get(tl.uri) orelse blk: {
                    const path = za.base.uri.toPath(a, tl.uri) catch break :blk "";
                    const x = Io.Dir.cwd().readFileAlloc(c.io, path, a, .limited(16 * 1024 * 1024)) catch "";
                    try texts.put(a, tl.uri, x);
                    break :blk x;
                };
                const to = offsetOf(tt, .{ .line = tl.line, .character = tl.character });
                if (to != null and std.mem.eql(u8, identAt(tt, to.?), name)) {
                    other_instance += 1;
                    continue;
                }
            };
            if (target == null or !locEql(target.?, decl_loc)) {
                false_pos += 1;
                if (shown < 10) {
                    shown += 1;
                    std.debug.print("    false positive `{s}` ({s}:{d}): {s}:{d}:{d}\n", .{ name, rel, decl_pos.line + 1, std.fs.path.basename(l.uri), l.line + 1, l.character + 1 });
                }
            }
        }
        // Identifiers in this file with the same name whose declaration points to that declaration
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
        // The edits of rename are at the same positions as the references
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
    if (bad_name + false_pos + missing + rename_mismatch > 0) checkFailed("find references and rename in {s}: wrong name {d}, false positives {d}, missing {d}, rename mismatches {d}", .{ rel, bad_name, false_pos, missing, rename_mismatch });
    std.debug.print("  references   checked {d} declarations, {d} references: wrong name {d}, false positives {d}, missing in this file {d}, rename mismatches {d}, other instances {d}\n", .{ checked, total_refs, bad_name, false_pos, missing, rename_mismatch, other_instance });
}

/// Completion recall (BENCH_COMPLETE=<n>): for each member access `a.b` in the source (with an
/// identifier, `)`, or `]` before the `.`), requests completion after the `.`; the list must
/// contain `b`. Samples n sites evenly and prints the recall and the samples that were missed
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
            // Labels of the form `@"struct"` are compared by the name inside
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
    if (found * 100 < n * 95) checkFailed("completion recall in {s} is below 95%: {d}/{d}", .{ rel, found, n });
    std.debug.print("  completion   checked {d} member accesses: offered {d} ({d:.1}%), empty lists {d}\n", .{ n, found, @as(f64, @floatFromInt(found)) * 100 / @as(f64, @floatFromInt(@max(n, 1))), empty });
}

/// Long session (BENCH_SESSION=<rounds>): each round opens 25 files of the project (rotating
/// forward each round), runs hover, member and name completion, and edits, then closes them;
/// afterwards prints the memory of the heap, the InternPool, the main queries and the allocator,
/// to watch memory growth over a long run, and at the end the latencies of the session's requests
fn longSession(c: *Client, root: []const u8, rounds: usize) !void {
    const a = c.arena.allocator();
    const io = c.io;
    const files = try projectFiles(c, root);
    if (files.len == 0) return;
    const per_round = 25;
    std.debug.print("long session: {d} rounds × {d} files (of {d})\n", .{ rounds, per_round, files.len });
    std.debug.print("  {s:>5} {s:>8} {s:>8} {s:>9} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>9} {s:>9} {s:>6} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7}  {s}\n", .{ "round", "rss MB", "heap MB", "ip items", "ip MB", "infer MB", "body MB", "parse MB", "imp MB", "keys", "deps", "s", "small", "resid", "slots", "kept", "ret", "large", "dec k", "thp", "commit", "occupancy %" });
    const t0 = Io.Clock.awake.now(io);
    var version: i64 = 1;
    var hover_times: std.ArrayList(f64) = .empty;
    var member_times: std.ArrayList(f64) = .empty;
    var name_times: std.ArrayList(f64) = .empty;
    var idle_times: std.ArrayList(f64) = .empty;
    for (0..rounds) |round| {
        for (0..per_round) |k| {
            const path = files[(round * per_round + k) % files.len];
            const text = Io.Dir.cwd().readFileAllocOptions(io, path, a, .limited(8 * 1024 * 1024), .of(u8), 0) catch continue;
            const uri = try za.base.uri.fromPath(a, path);
            const doc = .{ .uri = uri };
            try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = version, .text = text } });
            version += 1;
            const idents = try samplePositions(a, text, false);
            const step = @max(1, idents.len / 10);
            var i: usize = 0;
            while (i < idents.len) : (i += step) {
                _, const t = try c.request("textDocument/hover", .{ .textDocument = doc, .position = idents[i] });
                try hover_times.append(a, t);
            }
            const dots = try samplePositions(a, text, true);
            if (dots.len > 0) {
                _, const t = try c.request("textDocument/completion", .{ .textDocument = doc, .position = dots[dots.len / 2] });
                try member_times.append(a, t);
            }
            // Completion after two characters of a name are typed: the auto-import index (built
            // only after the first completion at a name) also counts toward the session's memory
            if (idents.len > 0) {
                const at = idents[idents.len / 3];
                _, const t = try c.request("textDocument/completion", .{ .textDocument = doc, .position = .{ .line = at.line, .character = at.character + 2 } });
                try name_times.append(a, t);
            }
            const end = positionOf(text, text.len);
            try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = end, .end = end }, .text = "// x" }} });
            version += 1;
            try c.notify("textDocument/didClose", .{ .textDocument = doc });
        }
        _, const idle_t = try c.request("zig-analyzer/waitIdle", {});
        try idle_times.append(a, idle_t);
        const st, _ = try c.request("zig-analyzer/status", {});
        const o = st.object.get("result").?.object;
        var infer_b: i64 = 0;
        var body_b: i64 = 0;
        var parse_b: i64 = 0;
        var import_b: i64 = 0;
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
            if (std.mem.indexOf(u8, name, ".imports.") != null) import_b += b;
        }
        const mb = struct {
            fn f(x: i64) f64 {
                return @as(f64, @floatFromInt(x)) / (1024 * 1024);
            }
        }.f;
        // `small`: pages assigned to size classes; `resid`: their backed part with the segment
        // headers and retained pages; `slots`: live small blocks by class size; `kept` and `ret`:
        // empty pages retained and returned to the system; `dec k`: pages returned so far;
        // `occupancy %`: share of the assigned pages by the eighth of their blocks in use, the
        // last one full
        const al: ?json.ObjectMap = if (o.get("allocator")) |v| (if (v == .object) v.object else null) else null;
        const vm = commitMb(c.child.id.?);
        std.debug.print("  {d:>5} {s:>8} {d:>8.0} {d:>9} {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.1} {d:>9} {d:>9} {d:>6.0} {d:>7.0} {d:>7.0} {d:>7.0} {d:>7.0} {d:>7.0} {d:>7.0} {d:>7} {d:>7.0} {d:>7.0}  {s}\n", .{
            round + 1,
            try mbText(a, try rssMb(c.gpa, io, c.child.id.?), ""),
            mb(o.get("heap_bytes").?.integer),
            @as(u64, @intCast(o.get("intern_pool_items").?.integer)),
            mb(o.get("intern_pool_bytes").?.integer),
            mb(infer_b),
            mb(body_b),
            mb(parse_b),
            mb(import_b),
            @as(u64, @intCast(keys)),
            @as(u64, @intCast(deps)),
            @as(f64, @floatFromInt(t0.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_s,
            allocatorMb(al, "small"),
            allocatorMb(al, "resident"),
            allocatorMb(al, "live_slots"),
            allocatorMb(al, "retained"),
            allocatorMb(al, "returned"),
            allocatorMb(al, "large"),
            if (al) |obj| @as(u64, @intCast(obj.get("decommits").?.integer)) / 1000 else 0,
            hugePagesMb(c.gpa, io, c.child.id.?) orelse 0,
            if (vm) |v| v[0] else 0,
            try occupancyText(a, if (al) |obj| obj.get("occupancy") else null),
        });
        if (round + 1 == rounds) {
            // Last round: list the queries by bytes; the rest is unattributed (engine tables,
            // dependencies, Vfs, ...)
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
            std.debug.print("  peak resident memory {d:.0} MB\n", .{@as(f64, @floatFromInt(o.get("max_rss_kb").?.integer)) / 1024});
            if (vm) |v| std.debug.print("  peak private commit {d:.0} MB, peak working set {d:.0} MB\n", .{ v[1], v[2] });
            if (al) |obj| {
                std.debug.print("  allocator: {d} segments, at most {d:.0} MB assigned to size classes, {d} pages returned to the system, {d} taken back\n", .{
                    obj.get("segments").?.integer,
                    allocatorMb(al, "peak_small"),
                    obj.get("decommits").?.integer,
                    obj.get("recommits").?.integer,
                });
                std.debug.print("    {s:>6} {s:>9} {s:>9} {s:>6} {s:>12}  {s}\n", .{ "size", "pages MB", "live MB", "use %", "allocs", "occupancy %" });
                for (obj.get("classes").?.array.items) |cl| {
                    const size: u64 = @intCast(cl.object.get("size").?.integer);
                    const pages: u64 = @intCast(cl.object.get("pages").?.integer);
                    const live = @as(u64, @intCast(cl.object.get("live").?.integer)) * size;
                    const allocs: u64 = @intCast(cl.object.get("allocs").?.integer);
                    std.debug.print("    {d:>6} {d:>9.1} {d:>9.1} {d:>6.1} {d:>12}  {s}\n", .{
                        size,
                        mb(@intCast(pages)),
                        mb(@intCast(live)),
                        if (pages == 0) 0 else @as(f64, @floatFromInt(live)) * 100 / @as(f64, @floatFromInt(pages)),
                        allocs,
                        try occupancyText(a, cl.object.get("occupancy")),
                    });
                }
            }
        }
    }
    std.debug.print("  session latencies:\n", .{});
    Stats.print("hover", hover_times.items);
    Stats.print("member compl", member_times.items);
    Stats.print("name compl", name_times.items);
    Stats.print("waitIdle", idle_times.items);
}

/// Throughput (BENCH_CONCURRENT=<n>): opens the n largest files of the project (other than the
/// Byte ranges of the bodies of functions with a `comptime`, `anytype`, or `type` parameter;
/// functions nested in such a body are inside its range
fn genericBodies(a: Allocator, tree: *const std.zig.Ast) ![]const [2]u32 {
    var out: std.ArrayList([2]u32) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        var params = proto.iterate(tree);
        const generic = while (params.next()) |p| {
            if (p.anytype_ellipsis3) |t| if (tree.tokenTag(t) == .keyword_anytype) break true;
            if (p.comptime_noalias) |t| if (tree.tokenTag(t) == .keyword_comptime) break true;
            if (p.type_expr) |t| if (tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type")) break true;
        } else false;
        if (!generic) continue;
        const body = tree.nodeData(node).node_and_node[1];
        try out.append(a, .{ tree.tokenStart(tree.firstToken(body)), tree.tokenStart(tree.lastToken(body)) });
    }
    return out.items;
}

/// Offsets of the names after `.` in the bodies of generic functions: members, enum and decl
/// literals, and field names of initializers, whose declaration can depend on the instance
fn instanceNames(a: Allocator, gpa: Allocator, text: [:0]const u8) ![]const u32 {
    var tree = try std.zig.Ast.parse(gpa, text, .{});
    defer tree.deinit(gpa);
    const bodies = try genericBodies(a, &tree);
    var out: std.ArrayList(u32) = .empty;
    if (bodies.len == 0) return out.items;
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |t, i| {
        if (t != .identifier or i == 0 or tags[i - 1] != .period) continue;
        const start = tree.tokenStart(@intCast(i));
        for (bodies) |r| if (start > r[0] and start < r[1]) {
            try out.append(a, start);
            break;
        };
    }
    return out.items;
}

/// Whether the relative path `rel` is under the directory `dir` (either separator)
fn underDir(rel: []const u8, dir: []const u8) bool {
    if (rel.len <= dir.len) return false;
    for (dir, rel[0..dir.len]) |x, y| {
        const sep_x = x == '/' or x == '\\';
        const sep_y = y == '/' or y == '\\';
        if (x != y and !(sep_x and sep_y)) return false;
    }
    return rel[dir.len] == '/' or rel[dir.len] == '\\';
}

/// Length of the text of a hover result (0 for null)
fn hoverLength(result: json.Value) usize {
    if (result != .object) return 0;
    return switch (result.object.get("contents") orelse return 0) {
        .object => |o| if (o.get("value")) |v| (if (v == .string) v.string.len else 0) else 0,
        .string => |s| s.len,
        else => 0,
    };
}

/// Hover where a name can refer to a different declaration under each instance of the generic
/// function containing it (BENCH_INSTANCE_HOVER=<n>): samples n names after `.` in the bodies
/// of generic functions (`instanceNames`), evenly over the project's files in path order. The
/// project is loaded by opening `first`. Three passes run over the same names; in each, a
/// file is opened and the server idle before its names are requested, then it is closed:
/// hover (the first request at each name), definition (more than one target means the name has
/// different declarations under different instances), and hover again. With `tokens`, the first
/// pass requests semantic tokens for each file and waits for the server to be idle before the
/// hovers, as an editor with semantic highlighting does on opening a file: their last stage
/// computes the instances of generic functions, which the first hover then finds computed.
/// Without it, the first hover computes them itself.
fn instanceHover(c: *Client, root: []const u8, first: []const u8, n: usize, dirs: ?[]const u8, out_path: ?[]const u8, tokens: bool) !void {
    const a = c.arena.allocator();
    const io = c.io;
    {
        const path = try std.fs.path.join(a, &.{ root, first });
        const text = try Io.Dir.cwd().readFileAllocOptions(io, path, a, .unlimited, .of(u8), 0);
        const uri = try za.base.uri.fromPath(a, path);
        const t0 = Io.Clock.awake.now(io);
        try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
        _ = try c.request("zig-analyzer/waitIdle", {});
        std.debug.print("  open {s} → project idle {d:.1}ms\n", .{ first, ms(io, t0) });
        try c.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
    }
    const File = struct { rel: []const u8, uri: []const u8, text: [:0]const u8, offsets: []const u32 };
    var files: std.ArrayList(File) = .empty;
    var total: usize = 0;
    for (try projectFiles(c, root)) |path| {
        const rel = path[root.len + 1 ..];
        if (dirs) |d| {
            var it = std.mem.splitScalar(u8, d, ',');
            const inside = while (it.next()) |dir| {
                if (underDir(rel, dir)) break true;
            } else false;
            if (!inside) continue;
        }
        const text = try Io.Dir.cwd().readFileAllocOptions(io, path, a, .unlimited, .of(u8), 0);
        const offsets = try instanceNames(a, c.gpa, text);
        if (offsets.len == 0) continue;
        try files.append(a, .{ .rel = rel, .uri = try za.base.uri.fromPath(a, path), .text = text, .offsets = offsets });
        total += offsets.len;
    }
    const Sample = struct { file: usize, pos: Position, hover: f64 = 0, again: f64 = 0, definition: f64 = 0, targets: usize = 0, len: usize = 0 };
    const count = @min(n, total);
    const picked = try a.alloc(Sample, count);
    {
        var file: usize = 0;
        // Names in the files before `file`
        var before: usize = 0;
        for (picked, 0..) |*s, i| {
            const k = i * total / count;
            while (k >= before + files.items[file].offsets.len) {
                before += files.items[file].offsets.len;
                file += 1;
            }
            const f = files.items[file];
            s.* = .{ .file = file, .pos = positionOf(f.text, f.offsets[k - before]) };
        }
    }
    var sampled_files: usize = 0;
    for (picked, 0..) |s, i| {
        if (i == 0 or picked[i - 1].file != s.file) sampled_files += 1;
    }
    std.debug.print("instance hover: {d} names in {d} files, sampled from {d} names in {d} files\n", .{ count, sampled_files, total, files.items.len });
    var max_rss: ?f64 = null;
    var tokens_ms: f64 = 0;
    // Semantic tokens time of each file, in the order the files are opened
    var file_tokens: std.ArrayList(struct { file: usize, time: f64 }) = .empty;
    for ([_][]const u8{ "textDocument/hover", "textDocument/definition", "textDocument/hover" }, 0..) |method, pass| {
        const t_pass = Io.Clock.awake.now(io);
        var i: usize = 0;
        while (i < picked.len) {
            const f = files.items[picked[i].file];
            try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = f.uri, .languageId = "zig", .version = 1, .text = f.text } });
            _ = try c.request("zig-analyzer/waitIdle", {});
            if (pass == 0 and tokens) {
                const t_tokens = Io.Clock.awake.now(io);
                _ = try c.request("textDocument/semanticTokens/full", .{ .textDocument = .{ .uri = f.uri } });
                _ = try c.request("zig-analyzer/waitIdle", {});
                const time = ms(io, t_tokens);
                tokens_ms += time;
                try file_tokens.append(a, .{ .file = picked[i].file, .time = time });
            }
            const file = picked[i].file;
            while (i < picked.len and picked[i].file == file) : (i += 1) {
                const s = &picked[i];
                const resp, const t = try c.request(method, .{ .textDocument = .{ .uri = f.uri }, .position = s.pos });
                const result = resp.object.get("result") orelse .null;
                switch (pass) {
                    0 => {
                        s.hover = t;
                        s.len = hoverLength(result);
                    },
                    1 => {
                        s.definition = t;
                        s.targets = switch (result) {
                            .array => |arr| arr.items.len,
                            .object => 1,
                            else => 0,
                        };
                    },
                    else => s.again = t,
                }
            }
            try c.notify("textDocument/didClose", .{ .textDocument = .{ .uri = f.uri } });
            if (try rssMb(c.gpa, io, c.child.id.?)) |mb| max_rss = @max(max_rss orelse mb, mb);
        }
        const rss = try rssMb(c.gpa, io, c.child.id.?);
        std.debug.print("  pass {d} ({s}) {d:.1}s, memory {s}\n", .{ pass + 1, method["textDocument/".len..], ms(io, t_pass) / 1000, try mbText(a, rss, " MB") });
        if (pass == 0 and tokens) std.debug.print("  semantic tokens before the hovers {d:.1}s (not in the hover times)\n", .{tokens_ms / 1000});
        if (verbose) try c.phase(method);
    }
    var several: std.ArrayList(Sample) = .empty;
    for (picked) |s| if (s.targets > 1) try several.append(a, s);
    const Column = enum { hover, again, definition, len };
    const values = struct {
        fn of(al: Allocator, list: []const Sample, comptime col: Column) ![]f64 {
            const out = try al.alloc(f64, list.len);
            for (list, out) |s, *o| o.* = switch (col) {
                .hover => s.hover,
                .again => s.again,
                .definition => s.definition,
                .len => @floatFromInt(s.len),
            };
            return out;
        }
    }.of;
    var hover_total: f64 = 0;
    for (picked) |s| hover_total += s.hover;
    std.debug.print("  names with several targets: {d}/{d}\n", .{ several.items.len, count });
    std.debug.print("  first hover total {d:.0}ms\n", .{hover_total});
    Stats.print("hover", try values(a, picked, .hover));
    Stats.print("hover again", try values(a, picked, .again));
    Stats.print("definition", try values(a, picked, .definition));
    Stats.print("hover (sev.)", try values(a, several.items, .hover));
    Stats.print("again (sev.)", try values(a, several.items, .again));
    inline for (.{ .{ "all", picked }, .{ "several targets", several.items } }) |group| {
        const lens = try values(a, group[1], .len);
        if (lens.len > 0) {
            std.mem.sort(f64, lens, {}, std.sort.asc(f64));
            std.debug.print("  hover length ({s}): p50 {d:.0} p95 {d:.0} max {d:.0} bytes\n", .{ group[0], Stats.at(lens, 0.5), Stats.at(lens, 0.95), lens[lens.len - 1] });
        }
    }
    std.debug.print("  peak memory between files {s}\n", .{try mbText(a, max_rss, " MB")});
    const by_time = try a.dupe(Sample, picked);
    std.mem.sort(Sample, by_time, {}, struct {
        fn gt(_: void, x: Sample, y: Sample) bool {
            return x.hover > y.hover;
        }
    }.gt);
    std.debug.print("  slowest first hovers:\n", .{});
    for (by_time[0..@min(10, by_time.len)]) |s| {
        const f = files.items[s.file];
        std.debug.print("    {d:>8.1}ms {s}:{d}:{d} targets {d}  `{s}`\n", .{ s.hover, f.rel, s.pos.line + 1, s.pos.character + 1, s.targets, lineText(f.text, s.pos.line) });
    }
    if (out_path) |p| {
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        try w.writeAll("file\tline\tcolumn\thover_ms\tagain_ms\tdefinition_ms\ttargets\tlength\n");
        for (picked) |s| try w.print("{s}\t{d}\t{d}\t{d:.3}\t{d:.3}\t{d:.3}\t{d}\t{d}\n", .{ files.items[s.file].rel, s.pos.line + 1, s.pos.character + 1, s.hover, s.again, s.definition, s.targets, s.len });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = out.written() });
        if (tokens) {
            var tokens_out: std.Io.Writer.Allocating = .init(a);
            const tw = &tokens_out.writer;
            try tw.writeAll("file\ttokens_ms\n");
            for (file_tokens.items) |x| try tw.print("{s}\t{d:.3}\n", .{ files.items[x.file].rel, x.time });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.tokens", .{p}), .data = tokens_out.written() });
        }
    }
}

/// Throughput (BENCH_CONCURRENT=<n>): opens the n largest files of the project (other than the
/// measured ones) and requests their full semantic tokens right away, as an editor restoring n
/// tabs does, without waiting for the answers; reports the time from the first open to the last
/// answer, then until background work is done, the latency of each request, and the memory
/// afterwards
fn concurrentTokens(c: *Client, root: []const u8, n: usize, measured: []const []const u8) !void {
    const a = c.arena.allocator();
    const io = c.io;
    // The measured files are already open. They are compared by full path with native separators:
    // on Windows the project's files are listed with `\`, while the command line names them as
    // given (e.g. `src/Sema.zig`)
    const skip = try a.alloc([]const u8, measured.len);
    for (measured, skip) |m, *s| {
        const path = try std.fs.path.join(a, &.{ root, m });
        std.mem.replaceScalar(u8, path, '/', std.fs.path.sep);
        s.* = path;
    }
    const File = struct { path: []const u8, size: u64 };
    var files: std.ArrayList(File) = .empty;
    next_file: for (try projectFiles(c, root)) |path| {
        for (skip) |s| if (std.mem.eql(u8, path, s)) continue :next_file;
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try files.append(a, .{ .path = path, .size = st.size });
    }
    std.mem.sort(File, files.items, {}, struct {
        fn gt(_: void, x: File, y: File) bool {
            return x.size > y.size or (x.size == y.size and std.mem.lessThan(u8, x.path, y.path));
        }
    }.gt);
    const picked = files.items[0..@min(n, files.items.len)];
    const texts = try a.alloc([:0]const u8, picked.len);
    const uris = try a.alloc([]const u8, picked.len);
    var bytes: u64 = 0;
    for (picked, texts, uris) |f, *text, *uri| {
        text.* = try Io.Dir.cwd().readFileAllocOptions(io, f.path, a, .limited(64 * 1024 * 1024), .of(u8), 0);
        uri.* = try za.base.uri.fromPath(a, f.path);
        bytes += f.size;
    }
    const t0 = Io.Clock.awake.now(io);
    for (texts, uris) |text, uri| try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    const first_id = c.next_id;
    for (uris) |uri| {
        const id = c.next_id;
        c.next_id += 1;
        try c.send(.{ .jsonrpc = "2.0", .id = id, .method = "textDocument/semanticTokens/full", .params = .{ .textDocument = .{ .uri = uri } } });
    }
    const times = try a.alloc(f64, uris.len);
    var answered: usize = 0;
    var tokens: usize = 0;
    var errors: usize = 0;
    while (answered < uris.len) {
        const msg = try c.next();
        if (msg.object.get("method") != null) continue;
        const id = msg.object.get("id") orelse continue;
        if (id != .integer or id.integer < first_id or id.integer - first_id >= @as(i64, @intCast(uris.len))) continue;
        times[@intCast(id.integer - first_id)] = ms(io, t0);
        answered += 1;
        if (msg.object.get("error") != null) errors += 1;
        if (msg.object.get("result")) |r| if (r == .object) {
            tokens += r.object.get("data").?.array.items.len / 5;
        };
    }
    const all_answered = ms(io, t0);
    _ = try c.request("zig-analyzer/waitIdle", {});
    const idle = ms(io, t0);
    for (uris) |uri| try c.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
    std.debug.print("concurrent semantic tokens: {d} files ({d:.1} MB) opened at once; all answered {d:.0}ms, idle {d:.0}ms; {d} tokens, {d} errors\n", .{ uris.len, @as(f64, @floatFromInt(bytes)) / (1024 * 1024), all_answered, idle, tokens, errors });
    Stats.print("sem tokens", times);
    const st, _ = try c.request("zig-analyzer/status", {});
    const o = st.object.get("result").?.object;
    const al: ?json.ObjectMap = if (o.get("allocator")) |v| (if (v == .object) v.object else null) else null;
    std.debug.print("  memory {s}, peak {d:.0} MB, heap {d:.0} MB; allocator: small {d:.0} MB, resident {d:.0} MB, slots {d:.0} MB, kept {d:.0} MB, returned {d:.0} MB, large {d:.0} MB; {d} pages returned to the system, {d} taken back\n", .{
        try mbText(a, try rssMb(c.gpa, io, c.child.id.?), " MB"),
        @as(f64, @floatFromInt(o.get("max_rss_kb").?.integer)) / 1024,
        @as(f64, @floatFromInt(o.get("heap_bytes").?.integer)) / (1024 * 1024),
        allocatorMb(al, "small"),
        allocatorMb(al, "resident"),
        allocatorMb(al, "live_slots"),
        allocatorMb(al, "retained"),
        allocatorMb(al, "returned"),
        allocatorMb(al, "large"),
        if (al) |obj| obj.get("decommits").?.integer else 0,
        if (al) |obj| obj.get("recommits").?.integer else 0,
    });
    if (commitMb(c.child.id.?)) |v| std.debug.print("  private commit {d:.0} MB (peak {d:.0} MB), peak working set {d:.0} MB\n", .{ v[0], v[1], v[2] });
}

/// Line-end offset of the first function body statement (indented by at least 8 spaces, ending
/// with `;`) in the second half of the file
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

/// Compares the errors published after a build with what `zig build` prints for the same steps
/// and arguments: each must have a counterpart with the same file and message whose range contains
/// the printed location, and the printed notes must be among its related information. Reference
/// traces are not compared. The arguments come from `BENCH_CONFIG`, so a project with its own
/// `zig-analyzer.zon` is skipped: it may set others.
fn compareWithBuild(c: *Client, root: []const u8) !void {
    const a = c.arena.allocator();
    const io = c.io;
    if (std.mem.eql(u8, c.build_title, "zig build (generated files)")) {
        std.debug.print("  warning: not compared with zig build: the last build only made generated files\n", .{});
        return;
    }
    if (Io.Dir.cwd().statFile(io, try std.fs.path.join(a, &.{ root, "zig-analyzer.zon" }), .{})) |_| {
        std.debug.print("  warning: not compared with zig build: the project has a zig-analyzer.zon\n", .{});
        return;
    } else |_| {}
    var argv: std.ArrayList([]const u8) = .empty;
    const zig = c.configValue("zig", "path");
    try argv.append(a, if (zig != null and zig.? == .string) zig.?.string else "zig");
    var steps = std.mem.tokenizeScalar(u8, c.build_title, ' ');
    _ = steps.next();
    _ = steps.next();
    try argv.append(a, "build");
    while (steps.next()) |step| try argv.append(a, step);
    try argv.appendSlice(a, &.{ "--color", "off", "--error-style", "verbose" });
    if (c.configValue("build", "args")) |args| if (args == .array) for (args.array.items) |arg| try argv.append(a, arg.string);
    const run = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = root }, .stderr_limit = .unlimited, .stdout_limit = .unlimited });
    var bundle = try za.project.bsp.stderrErrors(c.gpa, io, root, run.stderr);
    defer bundle.deinit(c.gpa);

    const Published = struct { path: []const u8, diagnostic: json.Value, matched: bool = false };
    var published: std.ArrayList(Published) = .empty;
    var it = c.published.iterator();
    while (it.next()) |entry| for (entry.value_ptr.*) |d| {
        const severity = d.object.get("severity") orelse continue;
        if (severity != .integer or severity.integer != 1) continue;
        try published.append(a, .{ .path = try za.base.uri.toPath(a, entry.key_ptr.*), .diagnostic = d });
    };

    var printed: usize = 0;
    var missing: usize = 0;
    var missing_notes: usize = 0;
    if (bundle.errorMessageCount() > 0) for (bundle.getMessages()) |index| {
        const err = bundle.getErrorMessage(index);
        const loc = bundle.getSourceLocation(err.src_loc);
        const path = try std.fs.path.resolve(a, &.{ root, bundle.nullTerminatedString(loc.src_path) });
        const message = bundle.nullTerminatedString(err.msg);
        printed += 1;
        const found = for (published.items) |*p| {
            if (!std.mem.eql(u8, p.path, path) or !std.mem.eql(u8, p.diagnostic.object.get("message").?.string, message)) continue;
            const range = p.diagnostic.object.get("range").?.object;
            if (!positionWithin(.{ .line = loc.line, .character = loc.column }, range)) continue;
            break p;
        } else null;
        const p = found orelse {
            missing += 1;
            std.debug.print("    not published {s}:{d}:{d} {s}\n", .{ path, loc.line + 1, loc.column + 1, message });
            continue;
        };
        p.matched = true;
        const related = p.diagnostic.object.get("relatedInformation");
        for (bundle.getNotes(index)) |note_index| {
            const note = bundle.nullTerminatedString(bundle.getErrorMessage(note_index).msg);
            const has = related != null and for (related.?.array.items) |r| {
                if (std.mem.eql(u8, r.object.get("message").?.string, note)) break true;
            } else false;
            if (has) continue;
            missing_notes += 1;
            std.debug.print("    note not published {s}:{d}: {s}\n", .{ path, loc.line + 1, note });
        }
    };
    var extra: usize = 0;
    for (published.items) |p| if (!p.matched) {
        extra += 1;
        const start = p.diagnostic.object.get("range").?.object.get("start").?.object;
        std.debug.print("    not printed {s}:{d}:{d} {s}\n", .{ p.path, start.get("line").?.integer + 1, start.get("character").?.integer + 1, p.diagnostic.object.get("message").?.string });
    };
    std.debug.print("  save         `{s}` printed {d} errors: not published {d}, notes not published {d}, not printed {d}\n", .{ c.build_title, printed, missing, missing_notes, extra });
    if (printed == 0) std.debug.print("  warning: zig build printed no located errors; the measured file may not be compiled by this step\n", .{});
    if (missing + missing_notes + extra > 0) checkFailed("published diagnostics differ from `{s}`", .{c.build_title});
}

fn positionWithin(p: Position, range: json.ObjectMap) bool {
    const start = range.get("start").?.object;
    const end = range.get("end").?.object;
    const before = p.line < start.get("line").?.integer or (p.line == start.get("line").?.integer and p.character < start.get("character").?.integer);
    const after = p.line > end.get("line").?.integer or (p.line == end.get("line").?.integer and p.character > end.get("character").?.integer);
    return !before and !after;
}

/// An answer given right after opening a file
const EarlyAnswer = struct {
    method: []const u8,
    position: Position,
    response: json.Value,
    /// Whether the answer arrived before the first project load ended
    loading: bool,
};

/// Requests hover, goto, and completion at positions spread over the file without waiting for the
/// project to load
fn earlyAnswers(c: *Client, uri: []const u8, idents: []const Position, dots: []const Position) ![]EarlyAnswer {
    const a = c.arena.allocator();
    var out: std.ArrayList(EarlyAnswer) = .empty;
    inline for (.{ "textDocument/hover", "textDocument/definition", "textDocument/completion" }) |method| {
        const positions = if (comptime std.mem.eql(u8, method, "textDocument/completion")) dots else idents;
        const n = @min(positions.len, early_samples);
        for (0..n) |i| {
            const p = positions[i * positions.len / n];
            const resp, _ = try c.request(method, .{ .textDocument = .{ .uri = uri }, .position = p });
            try out.append(a, .{ .method = method, .position = p, .response = resp, .loading = c.loads_ended == 0 });
        }
    }
    return out.items;
}

/// Start of the note a hover has while a project is loading, as a markdown client gets it
const hover_loading_marker = "\n\n---\n\n_The project is still loading";

const EarlyDifference = enum { same, incomplete, different };

/// How an answer given while loading relates to the one after loading: `incomplete` means it only
/// lacks results (null, or fewer completion labels), `different` that it has wrong ones
fn compareEarly(a: Allocator, method: []const u8, before: json.Value, after: json.Value) !EarlyDifference {
    if (std.mem.eql(u8, method, "textDocument/completion")) {
        var labels: std.StringHashMapUnmanaged(void) = .empty;
        for (completionItems(after)) |item| try labels.put(a, item.object.get("label").?.string, {});
        const items = completionItems(before);
        for (items) |item| if (!labels.contains(item.object.get("label").?.string)) return .different;
        return if (items.len < labels.count()) .incomplete else .same;
    }
    const before_result = before.object.get("result") orelse .null;
    // The note saying that the project is loading is not part of the result being compared
    if (before_result == .object) if (before_result.object.get("contents")) |contents| {
        const value = contents.object.getPtr("value").?;
        if (std.mem.indexOf(u8, value.string, hover_loading_marker)) |end| value.string = value.string[0..end];
    };
    const after_result = after.object.get("result") orelse .null;
    if (before_result == .null) return if (after_result == .null) .same else .incomplete;
    const x = try json.Stringify.valueAlloc(a, before_result, .{});
    const y = try json.Stringify.valueAlloc(a, after_result, .{});
    return if (std.mem.eql(u8, x, y)) .same else .different;
}

/// Asks again at the positions of `early` now that the project is loaded and reports how the
/// answers given while loading compare
fn checkEarlyAnswers(c: *Client, uri: []const u8, rel: []const u8, early: []const EarlyAnswer) !void {
    const a = c.arena.allocator();
    if (c.load_tokens.items.len == 0) {
        std.debug.print("  while loading: not compared, no project was loaded\n", .{});
        return;
    }
    var counts: [@typeInfo(EarlyDifference).@"enum".field_names.len]usize = @splat(0);
    var during_load: usize = 0;
    var shown: usize = 0;
    for (early) |answer| {
        if (!answer.loading) continue;
        during_load += 1;
        const resp, _ = try c.request(answer.method, .{ .textDocument = .{ .uri = uri }, .position = answer.position });
        const difference = try compareEarly(a, answer.method, answer.response, resp);
        counts[@backingInt(difference)] += 1;
        if (difference != .same and shown < 10) {
            shown += 1;
            std.debug.print("    {t} while loading: {s} {s}:{d}:{d}\n", .{ difference, answer.method["textDocument/".len..], rel, answer.position.line + 1, answer.position.character + 1 });
            if (verbose) std.debug.print("      before {f}\n      after  {f}\n", .{ json.fmt(answer.response.object.get("result") orelse .null, .{}), json.fmt(resp.object.get("result") orelse .null, .{}) });
        }
    }
    std.debug.print("  while loading {d}/{d} answers: same {d}, incomplete {d}, different {d}\n", .{ during_load, early.len, counts[@backingInt(EarlyDifference.same)], counts[@backingInt(EarlyDifference.incomplete)], counts[@backingInt(EarlyDifference.different)] });
}

/// Latency of `initialize` over fresh server processes; a single sample also measures whatever
/// the first launch of a new binary costs
fn sampleInitialize(gpa: Allocator, io: Io, exe: []const u8, root_uri: []const u8) !void {
    var times: [initialize_samples]f64 = undefined;
    for (&times) |*t| {
        var c: Client = .{ .gpa = gpa, .io = io, .child = undefined, .reader = undefined, .writer = undefined, .arena = .init(gpa) };
        defer c.arena.deinit();
        const t0 = Io.Clock.awake.now(io);
        c.start = t0;
        try c.spawn(exe);
        _ = try c.initialize(root_uri);
        t.* = ms(io, t0);
        _ = try c.request("shutdown", {});
        try c.send(.{ .jsonrpc = "2.0", .method = "exit" });
        _ = try c.child.wait(io);
    }
    Stats.print("initialize", &times);
    reportTarget("start → initialize p50", Stats.at(&times, 0.5), 100);
}

fn semanticTokenData(a: Allocator, result: json.Value) ![]i64 {
    const items = result.object.get("data").?.array.items;
    const out = try a.alloc(i64, items.len);
    for (items, out) |v, *d| d.* = v.integer;
    return out;
}

/// Applies a response to a delta request to the tokens held by a client. The result is either
/// the full data or a list of edits, sorted by position, that refer to the previous data
fn applySemanticDelta(a: Allocator, data: *std.ArrayList(i64), result: json.Value) !void {
    if (result.object.get("edits")) |edits| {
        var i = edits.array.items.len;
        while (i > 0) {
            i -= 1;
            const edit = edits.array.items[i].object;
            const inserted = if (edit.get("data") != null) try semanticTokenData(a, edits.array.items[i]) else &[_]i64{};
            try data.replaceRange(a, @intCast(edit.get("start").?.integer), @intCast(edit.get("deleteCount").?.integer), inserted);
        }
    } else {
        data.clearRetainingCapacity();
        try data.appendSlice(a, try semanticTokenData(a, result));
    }
}

/// Warm semantic tokens: full, a 10-line range at positions spread over the file, and a delta after
/// inserting or removing a comment at the top of the file (the timing includes the edit). The
/// tokens obtained by applying the deltas must equal a full result at the end
fn measureSemanticTokens(c: *Client, uri: []const u8, text: []const u8, rel: []const u8, version: *i64) !void {
    const a = c.arena.allocator();
    const doc = .{ .uri = uri };
    _ = try c.request("zig-analyzer/waitIdle", {});
    _ = try c.request("textDocument/semanticTokens/full", .{ .textDocument = doc });

    var full_times: [20]f64 = undefined;
    for (&full_times) |*t| _, t.* = try c.request("textDocument/semanticTokens/full", .{ .textDocument = doc });
    Stats.print("sem full", &full_times);

    const lines: u32 = @intCast(std.mem.count(u8, text, "\n") + 1);
    var range_times: [20]f64 = undefined;
    for (0..2) |_| for (&range_times, 0..) |*t, i| {
        const start: u32 = @intCast(i * lines / range_times.len);
        const range = .{ .start = Position{ .line = start, .character = 0 }, .end = Position{ .line = @min(start + 10, lines), .character = 0 } };
        _, t.* = try c.request("textDocument/semanticTokens/range", .{ .textDocument = doc, .range = range });
    };
    Stats.print("sem range", &range_times);

    const first, _ = try c.request("textDocument/semanticTokens/full", .{ .textDocument = doc });
    var result = first.object.get("result").?;
    var data: std.ArrayList(i64) = .empty;
    try data.appendSlice(a, try semanticTokenData(a, result));
    const comment = "// bench\n";
    const top: Position = .{ .line = 0, .character = 0 };
    var delta_times: [20]f64 = undefined;
    for (&delta_times, 0..) |*t, i| {
        const t0 = Io.Clock.awake.now(c.io);
        if (i % 2 == 0) {
            try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version.* }, .contentChanges = &.{.{ .range = .{ .start = top, .end = top }, .text = comment }} });
        } else {
            try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version.* }, .contentChanges = &.{.{ .range = .{ .start = top, .end = Position{ .line = 1, .character = 0 } }, .text = "" }} });
        }
        version.* += 1;
        const resp, _ = try c.request("textDocument/semanticTokens/full/delta", .{ .textDocument = doc, .previousResultId = result.object.get("resultId").?.string });
        t.* = ms(c.io, t0);
        result = resp.object.get("result").?;
        try applySemanticDelta(a, &data, result);
    }
    Stats.print("sem delta", &delta_times);
    const last, _ = try c.request("textDocument/semanticTokens/full", .{ .textDocument = doc });
    if (!std.mem.eql(i64, data.items, try semanticTokenData(a, last.object.get("result").?))) checkFailed("semantic token deltas in {s} do not add up to the full result", .{rel});
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
    if (builtin.mode == .debug) std.debug.print("warning: built in Debug mode; latencies are not comparable with the targets (use -Doptimize=ReleaseSafe)\n", .{});
    const root = try Io.Dir.cwd().realPathFileAlloc(io, args[2], gpa);
    defer gpa.free(root);

    var c: Client = .{ .gpa = gpa, .io = io, .child = undefined, .reader = undefined, .writer = undefined, .arena = .init(gpa) };
    defer c.arena.deinit();
    const t_spawn = Io.Clock.awake.now(io);
    c.start = t_spawn;
    try c.spawn(args[1]);

    const a = c.arena.allocator();
    if (init.environ_map.get("BENCH_CONFIG")) |cfg| c.config = try json.parseFromSliceLeaky(json.Value, a, cfg, .{});
    const root_uri = try za.base.uri.fromPath(a, root);
    const init_resp = try c.initialize(root_uri);
    const encoding = init_resp.object.get("result").?.object.get("capabilities").?.object.get("positionEncoding");
    if (encoding == null or encoding.? != .string or !std.mem.eql(u8, encoding.?.string, "utf-8")) {
        std.debug.print("error: the server does not count positions in UTF-8\n", .{});
        return 1;
    }
    std.debug.print("cold start\n  initialize   {d:.1}ms\n", .{ms(io, t_spawn)});
    try c.notify("initialized", struct {}{});
    try sampleInitialize(gpa, io, args[1], root_uri);

    const instance_hover = init.environ_map.get("BENCH_INSTANCE_HOVER");
    if (instance_hover) |v| try instanceHover(&c, root, args[3], std.fmt.parseInt(usize, v, 10) catch 2000, init.environ_map.get("BENCH_INSTANCE_HOVER_DIRS"), init.environ_map.get("BENCH_INSTANCE_HOVER_OUT"), init.environ_map.get("BENCH_INSTANCE_HOVER_TOKENS") != null);
    for (args[3..], 0..) |rel, file_index| {
        if (instance_hover != null) break;
        const path = try std.fs.path.join(a, &.{ root, rel });
        const text = try Io.Dir.cwd().readFileAllocOptions(io, path, a, .unlimited, .of(u8), 0);
        const uri = try za.base.uri.fromPath(a, path);
        const doc = .{ .uri = uri };
        std.debug.print("{s} ({d} lines)\n", .{ rel, std.mem.count(u8, text, "\n") });

        const t_open = Io.Clock.awake.now(io);
        try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
        _ = try c.request("textDocument/documentSymbol", .{ .textDocument = doc });
        const to_syntax = ms(io, t_open);
        std.debug.print("  open → syntax          {d:.1}ms\n", .{to_syntax});
        reportTarget("open → syntax", to_syntax, 200);
        const first = samplePositions(a, text, false) catch unreachable;
        _, const first_hover = try c.request("textDocument/hover", .{ .textDocument = doc, .position = first[first.len / 2] });
        std.debug.print("  first hover            {d:.1}ms (open → {d:.1}ms)\n", .{ first_hover, ms(io, t_open) });
        // Only the first file opens before the project has loaded
        const cold = file_index == 0;
        const idents = try samplePositions(a, text, false);
        const dots = try samplePositions(a, text, true);
        var early: []const EarlyAnswer = &.{};
        if (cold) {
            reportTarget("open → first hover", ms(io, t_open), 3000);
            _ = try c.request("textDocument/definition", .{ .textDocument = doc, .position = first[first.len / 2] });
            reportTarget("open → first goto", ms(io, t_open), 3000);
            if (dots.len > 0) {
                _ = try c.request("textDocument/completion", .{ .textDocument = doc, .position = dots[dots.len / 2] });
                reportTarget("open → first completion", ms(io, t_open), 3000);
            }
            early = try earlyAnswers(&c, uri, idents, dots);
        }
        _ = try c.request("zig-analyzer/waitIdle", {});
        std.debug.print("  open → project idle    {d:.1}ms\n", .{ms(io, t_open)});
        if (cold) {
            try checkEarlyAnswers(&c, uri, rel, early);
            // A workspace symbol request waits for the index
            _, const symbol_ms = try c.request("workspace/symbol", .{ .query = "bench" });
            std.debug.print("  workspace symbol after idle {d:.1}ms\n", .{symbol_ms});
            if (c.index_ms) |t| {
                reportTarget("workspace symbol index", t + index_progress_delay_ms, 30000);
            } else {
                std.debug.print("  target       workspace symbol index: under {d}ms (no progress reported) met\n", .{index_progress_delay_ms});
            }
        }
        if (verbose) try c.phase("open + project load");
        if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("  memory after idle {d:.0} MB\n", .{mb});
        _, const first_after = try c.request("textDocument/hover", .{ .textDocument = doc, .position = first[0] });
        std.debug.print("  first hover after idle {d:.1}ms\n", .{first_after});
        // BENCH_HOVER=line:col: print the hover result at that position and its time
        if (init.environ_map.get("BENCH_HOVER")) |spec| {
            var it = std.mem.splitScalar(u8, spec, ':');
            const line = try std.fmt.parseInt(u32, it.next().?, 10);
            const col = try std.fmt.parseInt(u32, it.next().?, 10);
            const resp, const t = try c.request("textDocument/hover", .{ .textDocument = doc, .position = Position{ .line = line - 1, .character = col - 1 } });
            std.debug.print("  hover {s}: {d:.1}ms\n{f}\n", .{ spec, t, json.fmt(resp.object.get("result").?, .{}) });
            if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("  memory {d:.0} MB\n", .{mb});
        }

        // Warm state: warm up the same positions with one pass first, then time them
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
                    std.debug.print("    slow {s} {d}:{d} {d:.1}ms memory {s}  `{s}`\n", .{ method["textDocument/".len..], p.line + 1, p.character + 1, t, try memoryChangeText(a, before, after), lineText(text, p.line) });
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
            if (times.len > 0) reportTarget(method["textDocument/".len..] ++ " p95", Stats.at(times, 0.95), if (comptime std.mem.eql(u8, method, "textDocument/completion")) 100 else 50);
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

        var version: i64 = 2;
        if (init.environ_map.get("BENCH_TYPE_WORDS")) |spec| try typeWords(&c, uri, text, spec, init.environ_map.get("BENCH_TYPE_STMT") orelse "_ = |;", &version);

        // Edit → live diagnostics: add a syntax error at the end of the file, then undo it
        // (BENCH_QUICK skips the edit-related phases)
        if (init.environ_map.get("BENCH_QUICK") == null) {
            const end = positionOf(text, text.len);
            var edit_times: [10]f64 = undefined;
            var clear_times: [10]f64 = undefined;
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
            const debounce: f64 = if (c.configValue("diagnostics", "debounce_ms")) |d| @floatFromInt(d.integer) else default_debounce_ms;
            reportTarget("edit→diag p50 without debounce", @max(Stats.at(&edit_times, 0.5) - debounce, 0), 30);
            Stats.print("undo→clear", &clear_times);

            // Continuous typing: type a character every 30ms into a comment at the end of the file
            // and hover right after each keystroke. The write transaction of an edit waits for the
            // in-flight read transactions (diagnostics computation) to exit; the latency here
            // includes that wait
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

            // Edits in a function body (a common place for real edits; uses block-level incremental
            // reparse): take the first statement in the second half of the file that is indented by
            // at least 8 spaces and ends with `;`, add a syntax error at the end of its line and
            // undo it; then type continuously into a comment at the end of the line and hover
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
                reportTarget("body edit→diag p50 without debounce", @max(Stats.at(&body_edit_times, 0.5) - debounce, 0), 30);
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

            try measureSemanticTokens(&c, uri, text, rel, &version);

            // Typing completion (BENCH_TYPE_COMPLETE=<count>): insert a character into a name
            // expression, request completion immediately, then undo. The timing includes the edit
            // and the completion; also reports how often auto-import candidates appear and the
            // changes in the index queries
            if (init.environ_map.get("BENCH_TYPE_COMPLETE")) |v| {
                const wanted = std.fmt.parseInt(usize, v, 10) catch 40;
                const names = try typingPositions(a, text);
                const count = @min(wanted, names.len);
                if (count == 0) {
                    std.debug.print("  type→complete   no name expressions sampled\n", .{});
                } else {
                    const counts_before = try queryCounts(&c);
                    const times = try a.alloc(f64, count);
                    var offered: usize = 0;
                    for (times, 0..) |*t, i| {
                        const p = names[i * names.len / count];
                        const t0 = Io.Clock.awake.now(io);
                        try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = p.edit, .end = p.edit }, .text = "x" }} });
                        version += 1;
                        const resp, _ = try c.request("textDocument/completion", .{ .textDocument = doc, .position = p.complete });
                        t.* = ms(io, t0);
                        if (hasAutoImport(resp)) offered += 1;
                        try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .range = .{ .start = p.edit, .end = p.complete }, .text = "" }} });
                        version += 1;
                    }
                    Stats.print("type→complete", times);
                    std.debug.print("  type→complete   auto-import offered in {d}/{d}\n", .{ offered, count });
                    if (offered == 0) std.debug.print("  warning: no auto-import candidates were offered; the sample may not reach importable names\n", .{});
                    _ = try c.request("zig-analyzer/waitIdle", {});
                    const counts_after = try queryCounts(&c);
                    for (counts_after, counts_before) |after, before| if (after.n != before.n)
                        std.debug.print("    {s}: +{d}\n", .{ after.name, after.n - before.n });
                    if (verbose) try c.phase("typed completions");
                }
            }

            // Save → compiler diagnostics (BENCH_SAVE=1): write a semantic error at the end of the
            // file on disk (not reported by AstGen, only by the compiler), wait for the diagnostic
            // to appear after saving, then restore the original file and wait for the diagnostic to
            // clear. Rewrites a file in the project and restores it at the end
            const compare_saves = init.environ_map.get("BENCH_SAVE") != null;
            // Only a project's save starts a `zig build`, which the timing waits for
            if (compare_saves and c.load_tokens.items.len == 0) std.debug.print("  warning: save not measured: no project was loaded\n", .{});
            if (compare_saves and c.load_tokens.items.len != 0) {
                const bad = try std.mem.concat(a, u8, &.{ text, "\ncomptime {\n    _ = @as(u8, 300);\n}\n" });
                var save_times: [5]f64 = undefined;
                var restore_times: [5]f64 = undefined;
                defer Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
                // Timed until the build triggered by this save finishes (the diagnostics are
                // published with it)
                for (&save_times, &restore_times, 0..) |*ts, *tr, round| {
                    for ([_][]const u8{ bad, text }, [_]*f64{ ts, tr }) |content, out| {
                        _ = try c.request("zig-analyzer/waitIdle", {});
                        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
                        try c.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = content }} });
                        version += 1;
                        const done = c.builds_done;
                        const t0 = Io.Clock.awake.now(io);
                        try c.notify("textDocument/didSave", .{ .textDocument = doc });
                        // A build that completes before the client answers its progress create
                        // sends no progress at all (see src/server/progress.zig), so the build's
                        // end is also detected by idle: the save starts the build before the
                        // server handles the request
                        const idle_id = c.next_id;
                        c.next_id += 1;
                        try c.send(.{ .jsonrpc = "2.0", .id = idle_id, .method = "zig-analyzer/waitIdle" });
                        while (c.builds_done == done) {
                            const msg = try c.next();
                            if (msg.object.get("method") != null) continue;
                            const got = msg.object.get("id") orelse continue;
                            if (got == .integer and got.integer == idle_id) break;
                        }
                        out.* = ms(io, t0);
                        if (verbose) std.debug.print("    save: {s}\n", .{c.build_message});
                        if (round == 0 and content.ptr == bad.ptr) {
                            _ = try c.request("zig-analyzer/waitIdle", {});
                            try compareWithBuild(&c, root);
                        }
                    }
                }
                Stats.print("save→build", &save_times);
                reportTarget("save→build p50", Stats.at(&save_times, 0.5), 1000);
                Stats.print("restore", &restore_times);
            }
        }
    }
    if (init.environ_map.get("BENCH_CONCURRENT")) |v| try concurrentTokens(&c, root, try std.fmt.parseInt(usize, v, 10), args[3..]);
    if (init.environ_map.get("BENCH_SESSION")) |v| try longSession(&c, root, try std.fmt.parseInt(usize, v, 10));
    if (try rssMb(gpa, io, c.child.id.?)) |mb| std.debug.print("resident memory {d:.0} MB\n", .{mb});
    try printQueryTable(&c);
    _ = try c.request("shutdown", {});
    try c.send(.{ .jsonrpc = "2.0", .method = "exit" });
    _ = try c.child.wait(io);
    std.debug.print("checks failed: {d}, latency targets missed: {d}\n", .{ failures, targets_missed });
    return if (failures > 0) 1 else 0;
}
