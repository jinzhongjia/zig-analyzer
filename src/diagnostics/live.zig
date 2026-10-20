//! `live` 诊断来源：官方解析器 + AstGen（等价于 `zig ast-check`），保证与编译器一致。
//!
//! 自研 CST 的错误不参与诊断。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const ErrorBundle = std.zig.ErrorBundle;

const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const inputs = @import("../base/inputs.zig");
const mem = @import("../util/mem.zig");
const nesting = @import("../syntax/nesting.zig");
const Watchdog = @import("../util/watchdog.zig").Watchdog;

const log = std.log.scoped(.live);

pub const Diagnostic = struct {
    /// 字节偏移区间（ErrorBundle 的 span_start / span_end）
    start: u32,
    end: u32,
    message: []const u8,
    notes: []const Note,
};

pub const Note = struct {
    start: u32,
    end: u32,
    message: []const u8,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator.State,
    items: []const Diagnostic,
    /// ZIR 中记录的 `@import` 字符串（含函数体内的）。编译器正是沿这些 import 确定要做 AstGen 的文件；
    /// 解析错误或根结构的致命 AstGen 错误会导致不生成 ZIR，此时为空，与编译器行为一致。
    imports: []const []const u8,

    pub fn destroy(r: *Result, gpa: Allocator) void {
        var arena = r.arena.promote(gpa);
        arena.deinit();
    }
};

pub const Mode = enum { zig, zon };

/// `.zon` 文件按 ZON 处理
pub fn modeOf(path: []const u8) Mode {
    return if (std.mem.endsWith(u8, path, ".zon")) .zon else .zig;
}

/// 对文本运行解析与 AstGen（或 ZonGen），返回全部错误。按嵌套深度选择执行的线程，深层嵌套的文本
/// 不会耗尽原生栈
pub fn check(gpa: Allocator, text: []const u8, mode: Mode) Allocator.Error!*Result {
    const source = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(source);
    const depth = try nesting.estimate(gpa, source, nesting.thread_depth);
    if (depth <= nesting.inline_depth) return checkSource(gpa, source, mode);
    if (depth <= nesting.thread_depth) {
        var result: Allocator.Error!*Result = undefined;
        if (std.Thread.spawn(.{ .stack_size = nesting.thread_stack_size }, checkInto, .{ gpa, source, mode, &result })) |thread| {
            thread.join();
            return result;
        } else |err| log.warn("cannot spawn a thread for AstGen of a deeply nested file: {t}", .{err});
    }
    return importsOnly(gpa, source, mode);
}

fn checkInto(gpa: Allocator, source: [:0]const u8, mode: Mode, result: *Allocator.Error!*Result) void {
    result.* = checkSource(gpa, source, mode);
}

/// 不做 AstGen 时的结果：没有诊断，import 按 token 收集（AstGen 记录的正是 `@import` 的字符串字面量）
fn importsOnly(gpa: Allocator, source: [:0]const u8, mode: Mode) Allocator.Error!*Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var imports: std.ArrayList([]const u8) = .empty;
    if (mode == .zig) {
        var tokenizer: std.zig.Tokenizer = .init(source);
        // 前两个 token：`@import` 与 `(`
        var prev: [2]std.zig.Token = @splat(.{ .tag = .invalid, .loc = .{ .start = 0, .end = 0 } });
        while (true) {
            const t = tokenizer.next();
            if (t.tag == .eof) break;
            if (t.tag == .string_literal and prev[1].tag == .l_paren and prev[0].tag == .builtin and
                std.mem.eql(u8, source[prev[0].loc.start..prev[0].loc.end], "@import"))
            {
                const name = std.zig.string_literal.parseAlloc(arena, source[t.loc.start..t.loc.end]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidLiteral => null,
                };
                if (name) |n| try imports.append(arena, n);
            }
            prev = .{ prev[1], t };
        }
    }
    const result = try arena.create(Result);
    result.* = .{ .arena = undefined, .items = &.{}, .imports = imports.items };
    result.arena = arena_state.state;
    return result;
}

fn checkSource(gpa: Allocator, source: [:0]const u8, mode: Mode) Allocator.Error!*Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = try Ast.parse(gpa, source, .{ .mode = switch (mode) {
        .zig => .zig,
        .zon => .zon,
    } });
    defer tree.deinit(gpa);

    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    var imports: std.ArrayList([]const u8) = .empty;
    switch (mode) {
        .zig => {
            var zir = try std.zig.AstGen.generate(gpa, tree);
            defer zir.deinit(gpa);
            if (zir.hasCompileErrors()) try wip.addZirErrorMessages(zir, tree, source, "");
            const payload = zir.extra[@backingInt(std.zig.Zir.ExtraIndex.imports)];
            if (payload != 0) {
                const header = zir.extraData(std.zig.Zir.Inst.Imports, payload);
                var extra_index = header.end;
                for (0..header.data.imports_len) |_| {
                    const item = zir.extraData(std.zig.Zir.Inst.Imports.Item, extra_index);
                    extra_index = item.end;
                    try imports.append(arena, try arena.dupe(u8, zir.nullTerminatedString(item.data.name)));
                }
            }
        },
        .zon => {
            const zoir = try std.zig.ZonGen.generate(gpa, tree, .{});
            defer zoir.deinit(gpa);
            if (zoir.hasCompileErrors()) try wip.addZoirErrorMessages(zoir, tree, source, "");
        },
    }
    var bundle = try wip.toOwnedBundle("");
    defer bundle.deinit(gpa);

    var items: std.ArrayList(Diagnostic) = .empty;
    if (bundle.errorMessageCount() != 0) {
        for (bundle.getMessages()) |msg_index| {
            const msg = bundle.getErrorMessage(msg_index);
            const span = spanOf(bundle, msg.src_loc);
            const notes = try arena.alloc(Note, msg.notes_len);
            for (notes, bundle.getNotes(msg_index)) |*note, note_index| {
                const n = bundle.getErrorMessage(note_index);
                const note_span = spanOf(bundle, n.src_loc);
                note.* = .{ .start = note_span[0], .end = note_span[1], .message = try arena.dupe(u8, bundle.nullTerminatedString(n.msg)) };
            }
            try items.append(arena, .{
                .start = span[0],
                .end = span[1],
                .message = try arena.dupe(u8, bundle.nullTerminatedString(msg.msg)),
                .notes = notes,
            });
        }
    }

    const result = try arena.create(Result);
    result.* = .{ .arena = undefined, .items = items.items, .imports = imports.items };
    result.arena = arena_state.state;
    return result;
}

fn spanOf(bundle: ErrorBundle, loc: ErrorBundle.SourceLocationIndex) [2]u32 {
    if (loc == .none) return .{ 0, 0 };
    const sl = bundle.getSourceLocation(loc);
    return .{ sl.span_start, sl.span_end };
}

/// live 诊断的执行方式。进程内 AstGen 只有在用户 zig 与 zig-analyzer 编译时的版本完全相同时
/// 才与编译器一致；否则调用用户的 `zig ast-check`。
pub const Backend = union(enum) {
    in_process,
    /// 用户 zig 可执行文件路径
    subprocess: []const u8,
};

/// 当前使用的执行方式；启动后确认 zig 版本时写入，变化时所有 `AstCheck` 重算
pub const LiveBackend = struct {
    pub const kind: engine.Kind = .input;
    pub const Key = void;
    pub const Value = Backend;
    pub const default: Value = .in_process;

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .in_process => b == .in_process,
            .subprocess => |exe| b == .subprocess and std.mem.eql(u8, exe, b.subprocess),
        };
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        if (v.* == .subprocess) gpa.free(v.subprocess);
    }
};

/// 文件的 live 诊断。`.zon` 文件按 ZON 处理。
pub const AstCheck = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *Result;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const text = try ctx.get(inputs.FileText, file) orelse "";
        const vfs: *Vfs = ctx.db.env.vfs;
        const mode = modeOf(vfs.path(file));
        const backend = try ctx.get(LiveBackend, {});
        if (ctx.db.env.live_prepared) |p| if (p.take(ctx.db.io, text, mode, backend)) |r| return r;
        return checkWith(ctx.db.gpa, ctx.db.io, backend, text, mode);
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b;
    }

    pub fn bytes(v: Value) usize {
        return mem.arenaBytes(v.arena);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        v.*.destroy(gpa);
    }
};

/// 按执行方式对文本做 live 检查
pub fn checkWith(gpa: Allocator, io: Io, backend: Backend, text: []const u8, mode: Mode) (Allocator.Error || Io.Cancelable)!*Result {
    return switch (backend) {
        .in_process => check(gpa, text, mode),
        .subprocess => |zig_exe| checkSubprocess(gpa, io, zig_exe, text, mode) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            // zig 无法运行：没有 live 诊断（编译器诊断仍可用）
            else => empty(gpa),
        },
    };
}

/// 在读事务之外预先算好的 `checkWith` 结果，按文本、模式与执行方式索引。AstGen 与子进程 `zig ast-check`
/// 都不检查取消，在读事务中执行时写事务（逐字输入）要等它结束；诊断发布先在锁外算好放入这里，`AstCheck`
/// 计算时取走命中的结果。结果只取决于文本，因此不影响 query 的纯函数语义。容量很小：未被取走的结果
/// （memo 已有效）按先进先出淘汰
pub const Prepared = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,
    /// 每个文件最近一次准备好（已放入）的文本哈希：文本未变时不重复准备
    last: std.AutoHashMapUnmanaged(Vfs.FileId, u64) = .empty,
    /// `take` 命中的次数（统计与测试用）
    hits: usize = 0,

    const Entry = struct { mode: Mode, backend: BackendKind, text: []const u8, result: *Result };
    const BackendKind = std.meta.Tag(Backend);
    pub const capacity = 8;

    pub fn deinit(p: *Prepared) void {
        for (p.entries.items) |e| p.destroyEntry(e);
        p.entries.deinit(p.gpa);
        p.last.deinit(p.gpa);
    }

    pub fn hash(text: []const u8, mode: Mode, backend: Backend) u64 {
        return std.hash.Wyhash.hash(@as(u64, @backingInt(mode)) << 8 | @backingInt(std.meta.activeTag(backend)), text);
    }

    /// 文件的这个文本是否还需要准备。放入之后才算准备好：并发的两次发布可能都准备同一个文本（在读事务
    /// 之外重复一次 AstGen），但不会有发布在准备完成之前进入读事务、在其中做 AstGen
    pub fn claim(p: *Prepared, io: Io, file: Vfs.FileId, h: u64) bool {
        return !p.prepared(io, file, h);
    }

    /// 文件的这个文本是否已经准备好
    pub fn prepared(p: *Prepared, io: Io, file: Vfs.FileId, h: u64) bool {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        return if (p.last.get(file)) |last| last == h else false;
    }

    /// 放入文件 `file` 的 `checkWith(backend, text, mode)` 的结果，取得 `result` 的所有权，并记这个文本已准备好
    pub fn put(p: *Prepared, io: Io, file: Vfs.FileId, text: []const u8, mode: Mode, backend: Backend, result: *Result) Allocator.Error!void {
        errdefer result.destroy(p.gpa);
        const owned = try p.gpa.dupe(u8, text);
        errdefer p.gpa.free(owned);
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        try p.last.put(p.gpa, file, hash(text, mode, backend));
        const kind = std.meta.activeTag(backend);
        if (p.find(text, mode, kind) != null) {
            p.gpa.free(owned);
            result.destroy(p.gpa);
            return;
        }
        if (p.entries.items.len == capacity) p.destroyEntry(p.entries.orderedRemove(0));
        try p.entries.append(p.gpa, .{ .mode = mode, .backend = kind, .text = owned, .result = result });
    }

    /// 取走 `checkWith(backend, text, mode)` 的结果（调用方取得所有权）
    pub fn take(p: *Prepared, io: Io, text: []const u8, mode: Mode, backend: Backend) ?*Result {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        const i = p.find(text, mode, std.meta.activeTag(backend)) orelse return null;
        const e = p.entries.orderedRemove(i);
        p.gpa.free(e.text);
        p.hits += 1;
        return e.result;
    }

    fn find(p: *Prepared, text: []const u8, mode: Mode, backend: BackendKind) ?usize {
        for (p.entries.items, 0..) |e, i| if (e.mode == mode and e.backend == backend and std.mem.eql(u8, e.text, text)) return i;
        return null;
    }

    fn destroyEntry(p: *Prepared, e: Entry) void {
        p.gpa.free(e.text);
        e.result.destroy(p.gpa);
    }
};

fn empty(gpa: Allocator) Allocator.Error!*Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const result = try arena.allocator().create(Result);
    result.* = .{ .arena = undefined, .items = &.{}, .imports = &.{} };
    result.arena = arena.state;
    return result;
}

// ── 子进程后端：zig ast-check ────────────────────────────────────────

/// 通过 stdin 把文本交给 `zig ast-check --color off`，解析其错误输出。
/// 子进程模式下没有 import 列表（此时构建图也无法加载，不存在编译集合）。
pub fn checkSubprocess(gpa: Allocator, io: std.Io, zig_exe: []const u8, text: []const u8, mode: Mode) !*Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ zig_exe, "ast-check", "--color", "off" });
    if (mode == .zon) try argv.append(gpa, "--zon");
    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .pipe, .stdout = .ignore, .stderr = .pipe });
    defer child.kill(io);
    var watchdog: Watchdog = .{};
    watchdog.start(io, child.id.?, .{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } });
    defer watchdog.stop();

    // ast-check 先读完全部输入再输出，因此先写后读不会死锁
    {
        var buf: [4096]u8 = undefined;
        var w = child.stdin.?.writerStreaming(io, &buf);
        try w.interface.writeAll(text);
        try w.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var buf: [4096]u8 = undefined;
    var r = child.stderr.?.readerStreaming(io, &buf);
    const output = try r.interface.allocRemaining(gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(output);
    return parseAstCheckOutput(gpa, text, output);
}

/// 解析 `zig ast-check --color off` 的输出：
///
/// ```
/// <stdin>:2:9: error: unused local variable
///     var u = 1;
///         ^~~~~~
/// <stdin>:3:7: note: ...
/// ```
///
/// 标记行开头的空格数为区间起点的字节列，`^` 与 `~` 的个数为区间的字节长度（多行区间截断到首行行尾）。
pub fn parseAstCheckOutput(gpa: Allocator, text: []const u8, output: []const u8) Allocator.Error!*Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var items: std.ArrayList(Diagnostic) = .empty;
    var notes: std.ArrayList(Note) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const header = parseHeader(lines.items[i]) orelse continue;
        const line_start = lineStartOffset(text, header.line);
        var start: u32 = @intCast(@min(text.len, line_start + header.column));
        var end = start;
        // 紧随的「源码行 + 标记行」
        if (i + 2 < lines.items.len and parseHeader(lines.items[i + 1]) == null and isCaretLine(lines.items[i + 2])) {
            const caret = lines.items[i + 2];
            const first = std.mem.indexOfNone(u8, caret, " ").?;
            const len = std.mem.trimEnd(u8, caret[first..], " ").len;
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            start = @intCast(@min(line_end, line_start + first));
            end = @intCast(@min(line_end, start + len));
            i += 2;
        }
        switch (header.kind) {
            .@"error" => {
                if (items.items.len != 0) items.items[items.items.len - 1].notes = try notes.toOwnedSlice(arena);
                try items.append(arena, .{ .start = start, .end = end, .message = try arena.dupe(u8, header.message), .notes = &.{} });
            },
            .note => try notes.append(arena, .{ .start = start, .end = end, .message = try arena.dupe(u8, header.message) }),
        }
    }
    if (items.items.len != 0) items.items[items.items.len - 1].notes = try notes.toOwnedSlice(arena);

    const result = try arena.create(Result);
    result.* = .{ .arena = undefined, .items = items.items, .imports = &.{} };
    result.arena = arena_state.state;
    return result;
}

const Header = struct { line: u32, column: u32, kind: enum { @"error", note }, message: []const u8 };

/// `<stdin>:行:列: error|note: 文案`（行列从 1 开始）
fn parseHeader(line: []const u8) ?Header {
    const prefix = "<stdin>:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var rest = line[prefix.len..];
    const c1 = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const ln = std.fmt.parseInt(u32, rest[0..c1], 10) catch return null;
    rest = rest[c1 + 1 ..];
    const c2 = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const col = std.fmt.parseInt(u32, rest[0..c2], 10) catch return null;
    rest = rest[c2 + 1 ..];
    const kind: @FieldType(Header, "kind") = if (std.mem.startsWith(u8, rest, " error: "))
        .@"error"
    else if (std.mem.startsWith(u8, rest, " note: "))
        .note
    else
        return null;
    const marker: []const u8 = if (kind == .@"error") " error: " else " note: ";
    const message = rest[marker.len..];
    if (ln == 0 or col == 0) return null;
    return .{ .line = ln - 1, .column = col - 1, .kind = kind, .message = message };
}

fn isCaretLine(line: []const u8) bool {
    var has_caret = false;
    for (line) |c| switch (c) {
        ' ', '~' => {},
        '^' => has_caret = true,
        else => return false,
    };
    return has_caret;
}

fn lineStartOffset(text: []const u8, line: u32) usize {
    var current: u32 = 0;
    var i: usize = 0;
    while (current < line) : (current += 1) {
        i = (std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return text.len) + 1;
    }
    return i;
}

const testing = std.testing;

test "parse zig ast-check output" {
    const text = "const a = 1;\nconst a = 2;\nfn f() void {\n    var u = 1;\n}\n";
    const output =
        \\<stdin>:1:7: error: duplicate struct member name 'a'
        \\const a = 1;
        \\      ^
        \\<stdin>:2:7: note: duplicate name here
        \\const a = 2;
        \\      ^
        \\<stdin>:1:1: note: struct declared here
        \\const a = 1;
        \\^~~~~
        \\
    ;
    const r = try parseAstCheckOutput(testing.allocator, text, output);
    defer r.destroy(testing.allocator);
    try testing.expectEqual(1, r.items.len);
    const d = r.items[0];
    try testing.expectEqualStrings("duplicate struct member name 'a'", d.message);
    try testing.expectEqualStrings("a", text[d.start..d.end]);
    try testing.expectEqual(2, d.notes.len);
    try testing.expectEqualStrings("a", text[d.notes[0].start..d.notes[0].end]);
    try testing.expectEqualStrings("const", text[d.notes[1].start..d.notes[1].end]);
}

test "subprocess backend matches in-process (skipped when zig is not in PATH)" {
    const gpa = testing.allocator;
    var env = @import("../project/ZigEnv.zig").query(gpa, testing.io, null) catch |err| switch (err) {
        error.ZigNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer env.deinit(gpa);
    const samples = [_]struct { text: []const u8, mode: Mode }{
        .{ .text = "fn f() void {\n    var unused = 1;\n}\n", .mode = .zig },
        .{ .text = "const a = 1;\nconst a = 2;\n", .mode = .zig },
        .{ .text = "const = ;\n", .mode = .zig },
        .{ .text = "pub fn main() void {}\n", .mode = .zig },
        .{ .text = "fn f() void {\n    const s = \"中文\"; var x = s;\n}\n", .mode = .zig },
        .{ .text = ".{ .a = 1, .a = 2 }\n", .mode = .zon },
    };
    for (samples) |sample| {
        const in_process = try check(gpa, sample.text, sample.mode);
        defer in_process.destroy(gpa);
        const sub = try checkSubprocess(gpa, testing.io, env.zig_exe, sample.text, sample.mode);
        defer sub.destroy(gpa);
        try testing.expectEqual(in_process.items.len, sub.items.len);
        for (in_process.items, sub.items) |x, y| {
            try testing.expectEqualStrings(x.message, y.message);
            try testing.expectEqual(x.start, y.start);
            try testing.expectEqual(x.notes.len, y.notes.len);
        }
    }
}

fn expectMessages(text: []const u8, mode: Mode, expected: []const []const u8) !void {
    const r = try check(testing.allocator, text, mode);
    defer r.destroy(testing.allocator);
    try testing.expectEqual(expected.len, r.items.len);
    for (expected, r.items) |e, d| try testing.expectEqualStrings(e, d.message);
}

// 预期值取自 `zig ast-check` 的实际输出
test "errors match zig ast-check" {
    try expectMessages("fn f() void { var x = 1; }", .zig, &.{"unused local variable"});
    try expectMessages("const a = ;", .zig, &.{"expected expression, found ';'"});
    try expectMessages("const a = 1;\nconst a = 2;", .zig, &.{"duplicate struct member name 'a'"});
    try expectMessages("pub fn main() void {}", .zig, &.{});
}

test "ZON" {
    try expectMessages(".{ .a = 1 }", .zon, &.{});
    try expectMessages(".{ .a = 1, .a = 2 }", .zon, &.{"duplicate struct field name"});
}

test "deeply nested text: AstGen on a large stack, imports only beyond the limit" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    // 10000 项的加法链（`zig ast-check` 能检查）：官方 AstGen 在普通线程上耗尽栈（进程崩溃），在大栈线程上
    // 照常得到诊断
    try src.appendSlice(gpa, "const std = @import(\"std\");\nfn f() void {\n    var unused = 1;\n}\nconst x = ");
    for (0..10000) |_| try src.appendSlice(gpa, "1 + ");
    try src.appendSlice(gpa, "1;\n");
    {
        const r = try check(gpa, src.items, .zig);
        defer r.destroy(gpa);
        try testing.expectEqual(1, r.items.len);
        try testing.expectEqualStrings("unused local variable", r.items[0].message);
        try testing.expectEqual(1, r.imports.len);
    }
    // 超过上限：不做 AstGen，没有诊断，import 按 token 收集
    src.clearRetainingCapacity();
    try src.appendSlice(gpa, "const std = @import(\"std\");\nconst x = ");
    for (0..nesting.thread_depth) |_| try src.append(gpa, '(');
    try src.append(gpa, '1');
    for (0..nesting.thread_depth) |_| try src.append(gpa, ')');
    try src.appendSlice(gpa, ";\nfn g() void {\n    _ = @import(\"a\\x2ezig\");\n}\n");
    {
        const r = try check(gpa, src.items, .zig);
        defer r.destroy(gpa);
        try testing.expectEqual(0, r.items.len);
        try testing.expectEqual(2, r.imports.len);
        try testing.expectEqualStrings("std", r.imports[0]);
        try testing.expectEqualStrings("a.zig", r.imports[1]);
    }
}

test "ZIR import list matches the compiler" {
    const a = testing.allocator;
    // 函数体内的 import 也会被收录
    const ok = try check(a, "const x = @import(\"x.zig\");\nfn f() void { _ = @import(\"y.zig\"); }\n", .zig);
    defer ok.destroy(a);
    try testing.expectEqual(2, ok.imports.len);
    try testing.expectEqualStrings("x.zig", ok.imports[0]);
    try testing.expectEqualStrings("y.zig", ok.imports[1]);
    // 非致命 AstGen 错误：仍有 import
    const nonfatal = try check(a, "fn f() void { var u = 1; }\nconst d = @import(\"d.zig\");\n", .zig);
    defer nonfatal.destroy(a);
    try testing.expectEqual(1, nonfatal.imports.len);
    // 根结构的致命错误与解析错误：不生成 ZIR，没有 import
    const fatal = try check(a, "const a = 1;\nconst a = 2;\nconst d = @import(\"d.zig\");\n", .zig);
    defer fatal.destroy(a);
    try testing.expectEqual(0, fatal.imports.len);
    const broken = try check(a, "const d = @import(\"d.zig\");\nconst = ;\n", .zig);
    defer broken.destroy(a);
    try testing.expectEqual(0, broken.imports.len);
}

test "error locations and notes" {
    const text = "const a = 1;\nconst a = 2;";
    const r = try check(testing.allocator, text, .zig);
    defer r.destroy(testing.allocator);
    const d = r.items[0];
    try testing.expectEqualStrings("a", text[d.start..d.end]);
    try testing.expectEqual(2, d.notes.len);
    try testing.expectEqualStrings("duplicate name here", d.notes[0].message);
    try testing.expectEqualStrings("struct declared here", d.notes[1].message);
}

test "prepared results: matched by text, mode and backend, taken once, oldest evicted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p: Prepared = .{ .gpa = gpa };
    defer p.deinit();
    try p.put(io, @fromBackingInt(@as(u32, 1)), "const a = ;", .zig, .in_process, try check(gpa, "const a = ;", .zig));
    // 同样的文本不同的模式或执行方式不命中
    try std.testing.expectEqual(null, p.take(io, "const a = ;", .zon, .in_process));
    try std.testing.expectEqual(null, p.take(io, "const a = ;", .zig, .{ .subprocess = "zig" }));
    const r = p.take(io, "const a = ;", .zig, .in_process).?;
    defer r.destroy(gpa);
    try std.testing.expectEqual(1, r.items.len);
    try std.testing.expectEqual(null, p.take(io, "const a = ;", .zig, .in_process));

    for (0..Prepared.capacity + 1) |i| {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "const a = {d};", .{i});
        try p.put(io, @fromBackingInt(@as(u32, 1)), text, .zig, .in_process, try check(gpa, text, .zig));
    }
    try std.testing.expectEqual(Prepared.capacity, p.entries.items.len);
    try std.testing.expectEqual(null, p.take(io, "const a = 0;", .zig, .in_process));

    // 放入之后同一文件的同一文本不再准备，其他文本、其他执行方式仍需准备
    try std.testing.expect(!p.claim(io, @fromBackingInt(@as(u32, 1)), Prepared.hash("const a = 8;", .zig, .in_process)));
    try std.testing.expect(p.claim(io, @fromBackingInt(@as(u32, 1)), Prepared.hash("y", .zig, .in_process)));
    try std.testing.expect(p.claim(io, @fromBackingInt(@as(u32, 1)), Prepared.hash("const a = 8;", .zig, .{ .subprocess = "zig" })));
    try std.testing.expect(p.claim(io, @fromBackingInt(@as(u32, 2)), Prepared.hash("const a = 8;", .zig, .in_process)));
}
