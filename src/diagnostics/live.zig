//! `live` diagnostic source: the official parser + AstGen (equivalent to `zig ast-check`),
//! guaranteed to match the compiler.
//!
//! Errors from the in-house CST do not contribute to diagnostics.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ast = std.zig.Ast;
const ErrorBundle = std.zig.ErrorBundle;
const Environ = std.process.Environ;

const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const inputs = @import("../base/inputs.zig");
const mem = @import("../util/mem.zig");
const nesting = @import("../syntax/nesting.zig");
const Parse = @import("../syntax/Parse.zig");
const Watchdog = @import("../util/watchdog.zig").Watchdog;
const child_process = @import("../util/child_process.zig");

const log = std.log.scoped(.live);

pub const Diagnostic = struct {
    /// Byte offset range (span_start / span_end of the ErrorBundle)
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
    /// False when the check could not run (zig could not be started, crashed or timed out, or no
    /// thread could be spawned for a deeply nested file): `items` is empty and says nothing about
    /// the text, so the result is not memoized
    complete: bool = true,

    /// Same diagnostics, in the same order
    pub fn eql(a: *const Result, b: *const Result) bool {
        if (a.complete != b.complete or a.items.len != b.items.len) return false;
        for (a.items, b.items) |x, y| {
            if (x.start != y.start or x.end != y.end or !std.mem.eql(u8, x.message, y.message)) return false;
            if (x.notes.len != y.notes.len) return false;
            for (x.notes, y.notes) |m, n| {
                if (m.start != n.start or m.end != n.end or !std.mem.eql(u8, m.message, n.message)) return false;
            }
        }
        return true;
    }

    pub fn destroy(r: *Result, gpa: Allocator) void {
        var arena = r.arena.promote(gpa);
        arena.deinit();
    }

    /// A copy with the same diagnostics, owned by the caller
    pub fn clone(r: *const Result, gpa: Allocator) Allocator.Error!*Result {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const items = try arena.alloc(Diagnostic, r.items.len);
        for (r.items, items) |d, *item| {
            const notes = try arena.alloc(Note, d.notes.len);
            for (d.notes, notes) |n, *note| note.* = .{ .start = n.start, .end = n.end, .message = try arena.dupe(u8, n.message) };
            item.* = .{ .start = d.start, .end = d.end, .message = try arena.dupe(u8, d.message), .notes = notes };
        }
        const copy = try arena.create(Result);
        copy.* = .{ .arena = undefined, .items = items, .complete = r.complete };
        copy.arena = arena_state.state;
        return copy;
    }
};

pub const Mode = Parse.Mode;
pub const modeOf = Parse.modeOf;

/// Number of live checks (`checkWith`, either backend) in this process, counted in test builds: a
/// test checks that publishing does not check a text that it already prepared (see `Prepared`)
pub var check_count: std.atomic.Value(usize) = .init(0);

/// Runs parsing and AstGen (or ZonGen) on the text and returns all errors. The thread to run on is
/// chosen by nesting depth, so deeply nested text does not exhaust the native stack.
pub fn check(gpa: Allocator, text: []const u8, mode: Mode) Allocator.Error!*Result {
    const source = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(source);
    const depth = try nesting.estimate(gpa, source, nesting.thread_depth);
    if (depth <= nesting.inline_depth) return checkSource(gpa, source, mode);
    // Nested beyond the limit: no diagnostics, a result as final as any other
    if (depth > nesting.thread_depth) return noDiagnostics(gpa, true);
    var result: Allocator.Error!*Result = undefined;
    const thread = std.Thread.spawn(.{ .stack_size = nesting.threadStackSize(depth, nesting.thread_depth) }, checkInto, .{ gpa, source, mode, &result }) catch |err| {
        log.warn("cannot spawn a thread for AstGen of a deeply nested file: {t}", .{err});
        return failed(gpa);
    };
    thread.join();
    return result;
}

fn checkInto(gpa: Allocator, source: [:0]const u8, mode: Mode, result: *Allocator.Error!*Result) void {
    result.* = checkSource(gpa, source, mode);
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
    switch (mode) {
        .zig => {
            var zir = try std.zig.AstGen.generate(gpa, tree);
            defer zir.deinit(gpa);
            if (zir.hasCompileErrors()) try wip.addZirErrorMessages(zir, tree, source, "");
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
    result.* = .{ .arena = undefined, .items = items.items };
    result.arena = arena_state.state;
    return result;
}

fn spanOf(bundle: ErrorBundle, loc: ErrorBundle.SourceLocationIndex) [2]u32 {
    if (loc == .none) return .{ 0, 0 };
    const sl = bundle.getSourceLocation(loc);
    return .{ sl.span_start, sl.span_end };
}

/// Backend for live diagnostics. In-process AstGen matches the compiler only when the user's zig is
/// exactly the same version that zig-analyzer was built with; otherwise the user's `zig ast-check`
/// is invoked.
pub const Backend = union(enum) {
    in_process,
    /// Path of the user's zig executable
    subprocess: []const u8,
};

/// The backend currently in use; set when the zig version is confirmed after startup, and all
/// `AstCheck`s are recomputed when it changes
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

/// Live diagnostics of a file. `.zon` files are treated as ZON.
pub const AstCheck = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *Result;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const text = if (try ctx.get(inputs.FileText, file)) |t| t.bytes() else "";
        const vfs: *Vfs = ctx.db.env.vfs;
        const mode = modeOf(vfs.path(file));
        const backend = try ctx.get(LiveBackend, {});
        if (ctx.db.env.live_prepared) |p| if (try p.take(ctx.db.gpa, ctx.db.io, text, mode, backend)) |r| return r;
        const result = try checkWith(ctx.db.gpa, ctx.db.io, backend, ctx.db.env.zig_environ.load(.acquire), text, mode);
        // A check that could not run is computed again by the next read
        if (!result.complete) ctx.markIncomplete(.unavailable);
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.eql(b);
    }

    pub fn bytes(v: Value) usize {
        return mem.arenaBytes(v.arena);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        v.*.destroy(gpa);
    }
};

/// Runs the live check on the text with the given backend; `environ_map` is passed to the
/// `zig ast-check` child process of the subprocess backend (null: the current process's)
pub fn checkWith(gpa: Allocator, io: Io, backend: Backend, environ_map: ?*const Environ.Map, text: []const u8, mode: Mode) (Allocator.Error || Io.Cancelable)!*Result {
    if (builtin.is_test) _ = check_count.fetchAdd(1, .monotonic);
    return switch (backend) {
        .in_process => check(gpa, text, mode),
        .subprocess => |zig_exe| checkSubprocess(gpa, io, zig_exe, environ_map, text, mode) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            // zig cannot be run: no live diagnostics (compiler diagnostics are still available)
            else => failed(gpa),
        },
    };
}

/// AstGen results of texts that `take` hands out a copy of, indexed by text, mode and backend.
/// `claim`/`prepared` answer from `last` instead, so a text stays prepared for its file even after
/// its result has been evicted: the entries only save the check when a reader needs the result.
/// Neither AstGen nor a `zig ast-check` child process checks for cancellation, so when one runs
/// inside a read transaction, write transactions (typing) must wait for it to finish; diagnostics
/// publishing computes the result outside the lock first and puts it here, and `AstCheck` takes a
/// copy of a matching result when it computes. The compiler diagnostics pipeline takes a copy too
/// (see `compiler.collect`): the AstGen errors of a build are matched against the check of the same
/// text, so a file is not checked twice for one save. Results depend only on the text, so this does
/// not affect the pure-function semantics of queries. The capacity is small: entries are evicted in
/// FIFO order, and an evicted result is checked again when a reader needs it.
pub const Prepared = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    /// Results kept for `take`, oldest first
    entries: std.ArrayList(Entry) = .empty,
    /// Hash of the text most recently prepared (put) for each file: an unchanged text is not
    /// prepared again, whether or not its result is still in `entries`. Never pruned: 8 bytes per
    /// file ever prepared.
    last: std.AutoHashMapUnmanaged(Vfs.FileId, u64) = .empty,
    /// Number of `take` hits (for statistics and tests)
    hits: usize = 0,

    const Entry = struct {
        mode: Mode,
        /// The checker that produced `result`. In-process AstGen depends only on the text and the
        /// mode (`checkSource` reads no environment), so that entry is identified by those; a
        /// subprocess result comes from the `zig ast-check` of one executable, which the entry
        /// therefore records (and owns). The environment the child ran with is not part of it:
        /// `AstCheck` memos are not recomputed when `zig_environ` changes either, so an entry is no
        /// staler than the result that takes it.
        backend: Backend,
        text: []const u8,
        result: *Result,
    };
    pub const capacity = 8;

    pub fn deinit(p: *Prepared) void {
        for (p.entries.items) |e| p.destroyEntry(e);
        p.entries.deinit(p.gpa);
        p.last.deinit(p.gpa);
    }

    pub fn hash(text: []const u8, mode: Mode, backend: Backend) u64 {
        return std.hash.Wyhash.hash(@as(u64, @backingInt(mode)) << 8 | @backingInt(std.meta.activeTag(backend)), text);
    }

    /// Whether this text of the file still needs to be prepared. A text counts as prepared only
    /// once it has been put: two concurrent publishes may both prepare the same text (repeating
    /// AstGen once outside the read transaction), but no publish enters the read transaction before
    /// preparation completes and runs AstGen in it.
    pub fn claim(p: *Prepared, io: Io, file: Vfs.FileId, h: u64) bool {
        return !p.prepared(io, file, h);
    }

    /// Whether this text of the file has already been prepared
    pub fn prepared(p: *Prepared, io: Io, file: Vfs.FileId, h: u64) bool {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        return if (p.last.get(file)) |last| last == h else false;
    }

    /// Puts the result of `checkWith(backend, text, mode)` for file `file`, taking ownership of
    /// `result`, and records this text as prepared. `result` is complete: `AstCheck` runs a check
    /// that could not run again.
    pub fn put(p: *Prepared, io: Io, file: Vfs.FileId, text: []const u8, mode: Mode, backend: Backend, result: *Result) Allocator.Error!void {
        assert(result.complete);
        errdefer result.destroy(p.gpa);
        const owned_text = try p.gpa.dupe(u8, text);
        errdefer p.gpa.free(owned_text);
        const owned_backend: Backend = switch (backend) {
            .in_process => .in_process,
            .subprocess => |exe| .{ .subprocess = try p.gpa.dupe(u8, exe) },
        };
        errdefer freeBackend(p.gpa, owned_backend);
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        const h = hash(text, mode, backend);
        // Another publish already prepared this text
        if (p.find(text, mode, owned_backend) != null) {
            // Record it only after finding the entry, so that a text is marked prepared only when
            // reading it can find a result
            try p.last.put(p.gpa, file, h);
            freeBackend(p.gpa, owned_backend);
            p.gpa.free(owned_text);
            result.destroy(p.gpa);
            return;
        }
        if (p.entries.items.len == capacity) p.destroyEntry(p.entries.orderedRemove(0));
        try p.entries.append(p.gpa, .{ .mode = mode, .backend = owned_backend, .text = owned_text, .result = result });
        // Likewise: record the text only after its entry is in place. On failure, remove the entry
        // again so that the errdefers free the text, the backend and the result.
        p.last.put(p.gpa, file, h) catch |err| {
            _ = p.entries.pop();
            return err;
        };
    }

    /// Takes a copy of the result of `checkWith(backend, text, mode)`, allocated with `gpa` (the
    /// caller destroys it with the same allocator); the entry stays in the memo for the later
    /// readers of the same text
    pub fn take(p: *Prepared, gpa: Allocator, io: Io, text: []const u8, mode: Mode, backend: Backend) Allocator.Error!?*Result {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        const i = p.find(text, mode, backend) orelse return null;
        const copy = try p.entries.items[i].result.clone(gpa);
        p.hits += 1;
        return copy;
    }

    fn find(p: *Prepared, text: []const u8, mode: Mode, backend: Backend) ?usize {
        for (p.entries.items, 0..) |e, i| if (e.mode == mode and LiveBackend.eql(e.backend, backend) and std.mem.eql(u8, e.text, text)) return i;
        return null;
    }

    fn freeBackend(gpa: Allocator, backend: Backend) void {
        switch (backend) {
            .in_process => {},
            .subprocess => |exe| gpa.free(exe),
        }
    }

    fn destroyEntry(p: *Prepared, e: Entry) void {
        freeBackend(p.gpa, e.backend);
        p.gpa.free(e.text);
        e.result.destroy(p.gpa);
    }
};

/// A result without diagnostics; `complete` is false for a check that could not run
fn noDiagnostics(gpa: Allocator, complete: bool) Allocator.Error!*Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const result = try arena.allocator().create(Result);
    result.* = .{ .arena = undefined, .items = &.{}, .complete = complete };
    result.arena = arena.state;
    return result;
}

fn failed(gpa: Allocator) Allocator.Error!*Result {
    return noDiagnostics(gpa, false);
}

// ── Subprocess backend: zig ast-check ────────────────────────────────

/// Passes the text to `zig ast-check --color off` through stdin and parses its error output.
/// `environ_map`: the environment of the child process (null: the current process's).
pub fn checkSubprocess(gpa: Allocator, io: std.Io, zig_exe: []const u8, environ_map: ?*const Environ.Map, text: []const u8, mode: Mode) !*Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ zig_exe, "ast-check", "--color", "off" });
    if (mode == .zon) try argv.append(gpa, "--zon");
    var child = try child_process.spawn(io, .{ .argv = argv.items, .environ_map = environ_map, .stdin = .pipe, .stdout = .ignore, .stderr = .pipe });
    defer child.kill(io);
    var watchdog: Watchdog = .{};
    watchdog.start(io, child.id.?, .{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } });
    defer watchdog.stop();

    // ast-check reads all of its input before writing any output, so writing first and reading
    // afterwards cannot deadlock
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
    // The output of a check that did not finish (timed out, crashed) is partial: exit code 0 means
    // no errors and 1 errors
    watchdog.stop();
    const term = try child.wait(io);
    if (watchdog.expired()) return error.AstCheckTimedOut;
    switch (term) {
        .exited => |code| if (code > 1) return error.AstCheckFailed,
        else => return error.AstCheckFailed,
    }
    return parseAstCheckOutput(gpa, text, output);
}

/// Parses the output of `zig ast-check --color off`:
///
/// ```
/// <stdin>:2:9: error: unused local variable
///     var u = 1;
///         ^~~~~~
/// <stdin>:3:7: note: ...
/// ```
///
/// The number of leading spaces on the marker line is the byte column of the range start, and the
/// number of `^` and `~` is the byte length of the range (a multi-line range is truncated at the
/// end of its first line).
pub fn parseAstCheckOutput(gpa: Allocator, text: []const u8, output: []const u8) Allocator.Error!*Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var items: std.ArrayList(Diagnostic) = .empty;
    var notes: std.ArrayList(Note) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));

    // Position in the output and span of the last error
    var last_error: ?struct { line: u32, column: u32, start: u32, end: u32 } = null;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const header = parseHeader(lines.items[i]) orelse continue;
        const line_start = lineStartOffset(text, header.line);
        var start: u32 = @intCast(@min(text.len, line_start + header.column));
        var end = start;
        // The "source line + marker line" pair that follows
        if (i + 2 < lines.items.len and parseHeader(lines.items[i + 1]) == null and isCaretLine(lines.items[i + 2])) {
            const caret = lines.items[i + 2];
            const first = std.mem.indexOfNone(u8, caret, " ").?;
            const len = std.mem.trimEnd(u8, caret[first..], " ").len;
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            start = @intCast(@min(line_end, line_start + first));
            end = @intCast(@min(line_end, start + len));
            i += 2;
        } else if (header.kind == .note) if (last_error) |e| if (e.line == header.line and e.column == header.column) {
            // AstGen omits the source line of a note located exactly at its error
            // (`ErrorBundle.Wip.addZirErrorMessages`): the note has the error's span
            start = e.start;
            end = e.end;
        };
        switch (header.kind) {
            .@"error" => {
                if (items.items.len != 0) items.items[items.items.len - 1].notes = try notes.toOwnedSlice(arena);
                try items.append(arena, .{ .start = start, .end = end, .message = try arena.dupe(u8, header.message), .notes = &.{} });
                last_error = .{ .line = header.line, .column = header.column, .start = start, .end = end };
            },
            .note => try notes.append(arena, .{ .start = start, .end = end, .message = try arena.dupe(u8, header.message) }),
        }
    }
    if (items.items.len != 0) items.items[items.items.len - 1].notes = try notes.toOwnedSlice(arena);

    const result = try arena.create(Result);
    result.* = .{ .arena = undefined, .items = items.items };
    result.arena = arena_state.state;
    return result;
}

const Header = struct { line: u32, column: u32, kind: enum { @"error", note }, message: []const u8 };

/// `<stdin>:line:column: error|note: message` (lines and columns start at 1)
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

test "parse zig ast-check output: a note at its error's location has the error's span" {
    const text = "export fn f() void {\n    var x: u32 = 1;\n    _ = x;\n}\n";
    const output =
        \\<stdin>:2:9: error: local variable is never mutated
        \\    var x: u32 = 1;
        \\        ^
        \\<stdin>:2:9: note: consider using 'const'
        \\
    ;
    const r = try parseAstCheckOutput(testing.allocator, text, output);
    defer r.destroy(testing.allocator);
    const d = r.items[0];
    try testing.expectEqual(29, d.start);
    try testing.expectEqual(30, d.end);
    // Guards against a zero-width note: the compiler prints no source line for it
    try testing.expectEqual(29, d.notes[0].start);
    try testing.expectEqual(30, d.notes[0].end);
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
        .{ .text = "fn f() void {\n    const s = \"€€\"; var x = s;\n}\n", .mode = .zig },
        .{ .text = ".{ .a = 1, .a = 2 }\n", .mode = .zon },
    };
    for (samples) |sample| {
        const in_process = try check(gpa, sample.text, sample.mode);
        defer in_process.destroy(gpa);
        const sub = try checkSubprocess(gpa, testing.io, env.zig_exe, env.childEnviron(), sample.text, sample.mode);
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

// Expected values are taken from the actual output of `zig ast-check`
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

test "deeply nested text: AstGen on a large stack, nothing beyond the limit" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    // An addition chain of 10000 terms (which `zig ast-check` can check): the official AstGen
    // exhausts the stack on a normal thread (crashing the process), but on a large-stack thread it
    // produces diagnostics as usual
    try src.appendSlice(gpa, "const std = @import(\"std\");\nfn f() void {\n    var unused = 1;\n}\nconst x = ");
    for (0..10000) |_| try src.appendSlice(gpa, "1 + ");
    try src.appendSlice(gpa, "1;\n");
    {
        const r = try check(gpa, src.items, .zig);
        defer r.destroy(gpa);
        try testing.expectEqual(1, r.items.len);
        try testing.expectEqualStrings("unused local variable", r.items[0].message);
    }
    // Beyond the limit: no AstGen, no diagnostics
    src.clearRetainingCapacity();
    try src.appendSlice(gpa, "const std = @import(\"std\");\nconst x = ");
    for (0..nesting.thread_depth) |_| try src.append(gpa, '(');
    try src.append(gpa, '1');
    for (0..nesting.thread_depth) |_| try src.append(gpa, ')');
    try src.appendSlice(gpa, ";\nfn g() void {\n    var unused = 1;\n}\n");
    {
        const r = try check(gpa, src.items, .zig);
        defer r.destroy(gpa);
        try testing.expectEqual(0, r.items.len);
        try testing.expect(r.complete);
    }
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

test "prepared results: matched by text, mode and backend, copied out, oldest evicted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p: Prepared = .{ .gpa = gpa };
    defer p.deinit();
    const file: Vfs.FileId = @fromBackingInt(@as(u32, 1));
    const other_file: Vfs.FileId = @fromBackingInt(@as(u32, 2));
    try p.put(io, file, "const a = ;", .zig, .in_process, try check(gpa, "const a = ;", .zig));
    // The same text with a different mode or backend does not match
    try std.testing.expectEqual(null, try p.take(gpa, io, "const a = ;", .zon, .in_process));
    try std.testing.expectEqual(null, try p.take(gpa, io, "const a = ;", .zig, .{ .subprocess = "zig" }));
    const r = (try p.take(gpa, io, "const a = ;", .zig, .in_process)).?;
    defer r.destroy(gpa);
    try std.testing.expectEqual(1, r.items.len);
    // The entry stays: another reader of the same text gets the same diagnostics
    const again = (try p.take(gpa, io, "const a = ;", .zig, .in_process)).?;
    defer again.destroy(gpa);
    try std.testing.expect(r.eql(again));

    for (0..Prepared.capacity + 1) |i| {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "const b = {d};", .{i});
        try p.put(io, other_file, text, .zig, .in_process, try check(gpa, text, .zig));
    }
    try std.testing.expectEqual(Prepared.capacity, p.entries.items.len);
    // The result of the oldest text was evicted by the other file's texts, and a reader of it
    // checks the text again
    try std.testing.expectEqual(null, try p.take(gpa, io, "const a = ;", .zig, .in_process));
    // Eviction does not make the text unprepared: its file remembers the last text it prepared,
    // so publishing it again does not check it again (its AstCheck is still valid)
    try std.testing.expect(!p.claim(io, file, Prepared.hash("const a = ;", .zig, .in_process)));
    // Prepared per file: another file with the same text is prepared on its own
    try std.testing.expect(p.claim(io, other_file, Prepared.hash("const a = ;", .zig, .in_process)));
    // A text that is prepared is not prepared again; other texts and other backends still are
    try std.testing.expect(!p.claim(io, other_file, Prepared.hash("const b = 8;", .zig, .in_process)));
    try std.testing.expect(p.claim(io, other_file, Prepared.hash("y", .zig, .in_process)));
    try std.testing.expect(p.claim(io, other_file, Prepared.hash("const b = 8;", .zig, .{ .subprocess = "zig" })));
}

test "prepared results: a subprocess result is matched by its executable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p: Prepared = .{ .gpa = gpa };
    defer p.deinit();
    try p.put(io, @fromBackingInt(@as(u32, 1)), "const a = ;", .zig, .{ .subprocess = "zig-a" }, try check(gpa, "const a = ;", .zig));
    try std.testing.expectEqual(null, try p.take(gpa, io, "const a = ;", .zig, .{ .subprocess = "zig-b" }));
    try std.testing.expectEqual(null, try p.take(gpa, io, "const a = ;", .zig, .in_process));
    const r = (try p.take(gpa, io, "const a = ;", .zig, .{ .subprocess = "zig-a" })).?;
    r.destroy(gpa);
}

test "prepared results: a failed put does not record the text as prepared" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing: std.testing.FailingAllocator = .init(gpa, .{});
        var p: Prepared = .{ .gpa = failing.allocator() };
        defer p.deinit();
        const result = try check(gpa, "const a = ;", .zig);
        failing.fail_index = failing.alloc_index + i;
        const failed_put = if (p.put(io, @fromBackingInt(@as(u32, 1)), "const a = ;", .zig, .in_process, result)) |_| false else |_| true;
        // `put` owns the result, whether it succeeds or fails
        if (failed_put) {
            try testing.expect(!p.prepared(io, @fromBackingInt(@as(u32, 1)), Prepared.hash("const a = ;", .zig, .in_process)));
        } else {
            try testing.expect(p.prepared(io, @fromBackingInt(@as(u32, 1)), Prepared.hash("const a = ;", .zig, .in_process)));
            break;
        }
    }
}

test "results compare by their diagnostics" {
    const gpa = testing.allocator;
    const a = try check(gpa, "const a = ;", .zig);
    defer a.destroy(gpa);
    const b = try check(gpa, "const a = ;", .zig);
    defer b.destroy(gpa);
    const c = try check(gpa, "const a = 1;\nconst a = 2;", .zig);
    defer c.destroy(gpa);
    const none = try check(gpa, "const a = 1;", .zig);
    defer none.destroy(gpa);
    const not_run = try failed(gpa);
    defer not_run.destroy(gpa);
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(!none.eql(not_run));
}

test "a check that could not run is not memoized" {
    // A zig that failed once must not leave the file without live diagnostics until it is edited
    const World = @import("../names/resolve_test.zig").World;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/a.zig", "const a = ;");
    {
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(LiveBackend, {}, .{ .subprocess = try testing.allocator.dupe(u8, "/nonexistent/zig") }, .low);
    }
    var buf: [@import("../database.zig").Db.query_types.len]engine.QueryStats = undefined;
    const before = w.db.stats(&buf).incomplete_causes.get(.unavailable);
    for (0..2) |_| {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        const r = try ctx.get(AstCheck, added.file);
        try testing.expect(!r.complete);
    }
    try testing.expectEqual(before + 2, w.db.stats(&buf).incomplete_causes.get(.unavailable));
    {
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(LiveBackend, {}, .in_process, .low);
    }
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    const r = try ctx.get(AstCheck, added.file);
    try testing.expect(r.complete);
    try testing.expectEqual(1, r.items.len);
}
