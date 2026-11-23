//! `compiler` diagnostic source: converts the ErrorBundles in build results into per-file
//! diagnostics and merges them with live diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const live = @import("live.zig");
const Vfs = @import("../base/Vfs.zig");
const line_diff = @import("../util/line_diff.zig");
const Edit = line_diff.Edit;

/// Compiler diagnostics of one file in one build
pub const FileResult = struct {
    /// Disk text read when the build finished; the byte ranges of the diagnostics refer to it
    base_text: []const u8,
    items: []const Item,
};

pub const Item = struct {
    start: u32,
    end: u32,
    message: []const u8,
    /// Whether this is also an AstGen (`zig ast-check`) error. When the buffer has unsaved
    /// changes, such errors come from the live source instead.
    is_astgen: bool,
    /// The compiler's notes followed by the reference trace
    notes: []const Note,
    /// Number of compiler notes at the start of `notes`; the rest is the reference trace
    note_count: usize = 0,
    /// `@compileLog` output attached to this error (its lines, without the trailing newline),
    /// appended to the message when published; empty when there is none. Stored separately from
    /// `message`: dedup and AstGen matching both use the compiler's original message.
    compile_log: []const u8 = "",
};

pub const Note = struct {
    /// Absolute path
    path: []const u8,
    start: u32,
    end: u32,
    message: []const u8,
    /// Text of the note's file read when its build finished (the range refers to it); null when
    /// the file could not be read
    base_text: ?[]const u8 = null,
};

/// All results of one build, allocated in an arena together with this struct itself. Immutable
/// after creation and shared by reference counting: the owner (a project or a single-file
/// compile) and each reader hold one reference. A reader can release the owner's lock as soon
/// as it has taken a reference under that lock; once the result is replaced by a new one, it is
/// freed when the last reference is released.
pub const BuildResult = struct {
    arena: std.heap.ArenaAllocator.State,
    /// Absolute path → result
    files: std.StringArrayHashMapUnmanaged(FileResult),
    refs: std.atomic.Value(u32) = .init(1),

    pub fn retain(r: *BuildResult) *BuildResult {
        _ = r.refs.fetchAdd(1, .monotonic);
        return r;
    }

    pub fn release(r: *BuildResult, gpa: Allocator) void {
        if (r.refs.fetchSub(1, .acq_rel) != 1) return;
        var arena = r.arena.promote(gpa);
        arena.deinit();
    }
};

/// File reading interface: returns the current disk text of a file (null on failure)
pub const ReadFn = *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8;

/// AstGen results that `collect` can reuse: the ones that publishing computed for the same text,
/// with the lock of their mutex
pub const LiveCache = struct {
    io: std.Io,
    prepared: *live.Prepared,
};

/// Converts a set of ErrorBundles into per-file results.
/// A relative `src_path` is relative to `build_root`; errors without location information (such
/// as link errors) are attached to the start of `fallback_path` (usually build.zig), which is
/// copied into the result.
/// When `src_path` does not resolve to an absolute path (a malformed error bundle, see
/// `absolute`), it is treated as having no location: the error is attached to the start of
/// `fallback_path`, and the notes and reference trace are placed at the start of the error.
/// A message or note that the compiler merged from several identical ones (`count` above 1) gets
/// the same ` (N times)` suffix as in the compiler's output.
/// The files are read from disk after the build. A location that carries its source line (the
/// compiler gives one for errors and for notes not at the error's position) shows whether the
/// text read is the one the compiler read; when it is not (the file changed during the build), no
/// location in that file is kept: its errors are dropped with their notes, and notes and
/// references into it are dropped. The next build that reads the file reports them again.
/// `live_cache` supplies the AstGen results that publishing computed for the same texts; the
/// `is_astgen` flags are the same with or without it, since only in-process results are reused.
pub fn collect(
    gpa: Allocator,
    bundles: []const ErrorBundle,
    build_root: []const u8,
    fallback_path: []const u8,
    read_ctx: *anyopaque,
    read: ReadFn,
    live_cache: ?LiveCache,
) Allocator.Error!*BuildResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    // The caller may free `fallback_path` while the result is still in use
    const fallback = try a.dupe(u8, fallback_path);
    var sources: Sources = .{ .a = a, .build_root = build_root, .read_ctx = read_ctx, .read = read };
    // Find the files that changed after the compiler read them
    for (bundles) |eb| {
        if (eb.errorMessageCount() == 0) continue;
        for (eb.getMessages()) |mi| {
            try sources.check(eb, eb.getErrorMessage(mi).src_loc);
            for (eb.getNotes(mi)) |ni| try sources.check(eb, eb.getErrorMessage(ni).src_loc);
        }
    }

    var lists: std.StringArrayHashMapUnmanaged(std.ArrayList(Item)) = .empty;
    // Dedup: several compile steps may report the same error in the same file. Errors at the same
    // range with the same message but different notes (e.g. one per inline call site) are distinct
    // errors; the reference trace is not part of the identity. The value is the index of the kept
    // error in that file's list.
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    var key: std.ArrayList(u8) = .empty;

    for (bundles) |eb| {
        if (eb.errorMessageCount() == 0) continue;
        const log_text = try a.dupe(u8, std.mem.trimEnd(u8, eb.getCompileLogOutput(), "\n"));
        const log_target: ?ErrorBundle.MessageIndex = if (log_text.len == 0) null else try logTarget(a, eb, build_root);
        for (eb.getMessages()) |mi| {
            const msg = eb.getErrorMessage(mi);
            const message = try withCount(a, eb.nullTerminatedString(msg.msg), msg.count);
            const compile_log = if (log_target == mi) log_text else "";
            var path: []const u8 = fallback;
            var start: u32 = 0;
            var end: u32 = 0;
            if (msg.src_loc != .none) {
                const loc = eb.getSourceLocation(msg.src_loc);
                if (try absolute(a, build_root, eb.nullTerminatedString(loc.src_path))) |p| {
                    if (sources.stale.contains(p)) continue;
                    path = p;
                    start, end = byteSpan(loc);
                }
            }

            // The notes are followed by the reference trace
            const refs: u32 = if (msg.src_loc != .none) eb.getSourceLocation(msg.src_loc).reference_trace_len else 0;
            var notes: std.ArrayList(Note) = try .initCapacity(a, msg.notes_len + refs);
            for (eb.getNotes(mi)) |ni| {
                const n = eb.getErrorMessage(ni);
                var note: Note = .{ .path = path, .start = start, .end = start, .message = "" };
                if (n.src_loc != .none) {
                    const nl = eb.getSourceLocation(n.src_loc);
                    if (try absolute(a, build_root, eb.nullTerminatedString(nl.src_path))) |p| {
                        if (sources.stale.contains(p)) continue;
                        note.path = p;
                        note.start, note.end = byteSpan(nl);
                    }
                }
                note.message = try withCount(a, eb.nullTerminatedString(n.msg), n.count);
                note.base_text = try sources.text(note.path);
                notes.appendAssumeCapacity(note);
            }
            key.clearRetainingCapacity();
            try key.print(a, "{s}\x00{d}\x00{d}\x00{s}", .{ path, start, end, message });
            for (notes.items) |n| try key.print(a, "\x00{s}\x00{d}\x00{d}\x00{s}", .{ n.path, n.start, n.end, n.message });
            const seen_gop = try seen.getOrPut(a, key.items);
            if (seen_gop.found_existing) {
                try addCompileLog(a, &lists.getPtr(path).?.items[seen_gop.value_ptr.*], compile_log);
                continue;
            }
            seen_gop.key_ptr.* = try a.dupe(u8, key.items);
            const note_count = notes.items.len;
            if (refs != 0) try referenceTrace(eb, msg.src_loc, refs, &sources, path, start, &notes);
            const gop = try lists.getOrPut(a, path);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            seen_gop.value_ptr.* = gop.value_ptr.items.len;
            try gop.value_ptr.append(a, .{ .start = start, .end = end, .message = message, .is_astgen = false, .notes = notes.items, .note_count = note_count, .compile_log = compile_log });
        }
    }

    var files: std.StringArrayHashMapUnmanaged(FileResult) = .empty;
    for (lists.keys(), lists.values()) |path, *items| {
        const text = try sources.text(path) orelse "";
        // Mark AstGen errors: match the errors against in-process AstGen of the same text, reusing
        // the check that publishing already ran on it
        const astgen = try astgenOf(gpa, live_cache, text, live.modeOf(path));
        defer astgen.destroy(gpa);
        for (items.items) |*item| {
            for (astgen.items) |d| {
                if (d.start == item.start and d.end == item.end and std.mem.eql(u8, d.message, item.message)) item.is_astgen = true;
            }
        }
        try files.put(a, path, .{ .base_text = text, .items = items.items });
    }
    const result = try a.create(BuildResult);
    result.* = .{ .arena = undefined, .files = files };
    // Take the arena state after the last allocation
    result.arena = arena_state.state;
    return result;
}

/// In-process AstGen of the text, whose errors the `is_astgen` flag compares against. A result that
/// live diagnostics computed for the same text is taken from `live_cache` instead of checking the
/// text again. Only in-process results are taken: `LiveBackend` may be the user's `zig ast-check`,
/// whose diagnostics are not necessarily the ones this AstGen produces.
fn astgenOf(gpa: Allocator, live_cache: ?LiveCache, text: []const u8, mode: live.Mode) Allocator.Error!*live.Result {
    if (live_cache) |cache| if (try cache.prepared.take(gpa, cache.io, text, mode, .in_process)) |result| return result;
    return live.check(gpa, text, mode);
}

/// Disk texts of the files that the locations of a build point into, read after the build
const Sources = struct {
    a: Allocator,
    build_root: []const u8,
    read_ctx: *anyopaque,
    read: ReadFn,
    texts: std.StringHashMapUnmanaged([]const u8) = .empty,
    unreadable: std.StringHashMapUnmanaged(void) = .empty,
    /// Files whose text read is not the one the compiler read
    stale: std.StringHashMapUnmanaged(void) = .empty,

    /// Text of `path`, read once; null when it cannot be read
    fn text(s: *Sources, path: []const u8) Allocator.Error!?[]const u8 {
        if (s.texts.get(path)) |t| return t;
        if (s.unreadable.contains(path)) return null;
        const t = s.read(s.read_ctx, s.a, path) orelse {
            try s.unreadable.put(s.a, path, {});
            return null;
        };
        try s.texts.put(s.a, path, t);
        return t;
    }

    /// Marks the file of `src_loc` stale when the location carries its source line and the text
    /// read does not have that line at the location's main position, with that position at the
    /// same column (both as `std.zig.findLineColumn` computes them on the text the compiler read)
    fn check(s: *Sources, eb: ErrorBundle, src_loc: ErrorBundle.SourceLocationIndex) Allocator.Error!void {
        if (src_loc == .none) return;
        const loc = eb.getSourceLocation(src_loc);
        if (loc.source_line == 0) return;
        const path = try absolute(s.a, s.build_root, eb.nullTerminatedString(loc.src_path)) orelse return;
        const t = try s.text(path) orelse "";
        const main = loc.span_main;
        const same = main <= t.len and blk: {
            const line_start = if (std.mem.lastIndexOfScalar(u8, t[0..main], '\n')) |i| i + 1 else 0;
            const line_end = std.mem.indexOfScalarPos(u8, t, main, '\n') orelse t.len;
            break :blk main - line_start == loc.column and std.mem.eql(u8, t[line_start..line_end], eb.nullTerminatedString(loc.source_line));
        };
        if (!same) try s.stale.put(s.a, path, {});
    }
};

/// Appends the `count` references of the reference trace following source location `src_loc` to
/// `out` as notes, with messages matching the output of `zig build`; references into a stale file
/// (see `Sources`) are left out. A reference with a location points to the referencing site; the
/// trailing hidden marker has no location and, like notes without a location, is placed at the
/// start of the error (`start` in `path`).
fn referenceTrace(
    eb: ErrorBundle,
    src_loc: ErrorBundle.SourceLocationIndex,
    count: u32,
    sources: *Sources,
    path: []const u8,
    start: u32,
    out: *std.ArrayList(Note),
) Allocator.Error!void {
    const a = sources.a;
    // ErrorBundle has no public interface for reading the reference trace: it is read from
    // `extra` according to its layout. `SourceLocation` is followed by the `ReferenceTrace`s one
    // after another, each storing `decl_name` and `src_loc` in field order.
    const first = @backingInt(src_loc) + @typeInfo(ErrorBundle.SourceLocation).@"struct".field_names.len;
    const stride = @typeInfo(ErrorBundle.ReferenceTrace).@"struct".field_names.len;
    for (0..count) |k| {
        const at = first + k * stride;
        const decl_name: ErrorBundle.String = eb.extra[at];
        const ref_loc: ErrorBundle.SourceLocationIndex = @fromBackingInt(eb.extra[at + 1]);
        var note: Note = .{ .path = path, .start = start, .end = start, .message = "" };
        if (ref_loc != .none) {
            const rl = eb.getSourceLocation(ref_loc);
            if (try absolute(a, sources.build_root, eb.nullTerminatedString(rl.src_path))) |p| {
                if (sources.stale.contains(p)) continue;
                note.path = p;
                note.start, note.end = byteSpan(rl);
            }
            note.message = try std.fmt.allocPrint(a, "referenced by: {s}", .{eb.nullTerminatedString(decl_name)});
        } else if (decl_name != 0) {
            // Hidden marker: `decl_name` is the number of hidden references
            note.message = try std.fmt.allocPrint(a, "{d} reference(s) hidden; use '-freference-trace={d}' to see all references", .{ decl_name, @as(usize, decl_name) + count - 1 });
        } else {
            note.message = "remaining reference traces hidden; use '-freference-trace' to see all reference traces";
        }
        note.base_text = try sources.text(note.path);
        out.appendAssumeCapacity(note);
    }
}

/// When only one of several duplicate errors is kept, the compile log of a dropped one is merged
/// into the kept one (identical logs are kept only once)
fn addCompileLog(a: Allocator, item: *Item, compile_log: []const u8) Allocator.Error!void {
    if (compile_log.len == 0 or std.mem.eql(u8, item.compile_log, compile_log)) return;
    item.compile_log = if (item.compile_log.len == 0) compile_log else try std.mem.join(a, "\n", &.{ item.compile_log, compile_log });
}

/// Text of a message or note as the compiler prints it: a message merged from `count` identical
/// ones ends with ` (N times)` when `count` is not 1 (`ErrorBundle.renderErrorMessage`)
fn withCount(a: Allocator, text: []const u8, count: u32) Allocator.Error![]const u8 {
    if (count == 1) return a.dupe(u8, text);
    return std.fmt.allocPrint(a, "{s} ({d} times)", .{ text, count });
}

/// The error of `eb` that its `@compileLog` output is attached to: the "found compile log
/// statement" error, which the compiler reports only when there is no other error. Otherwise
/// the output belongs to no error, and it is attached to the first error located under
/// `build_root`, so that it shows up in the project's code rather than in a dependency or the
/// standard library that the compiler sorts first; to the first error when none is.
fn logTarget(a: Allocator, eb: ErrorBundle, build_root: []const u8) Allocator.Error!ErrorBundle.MessageIndex {
    const messages = eb.getMessages();
    for (messages) |mi| {
        if (std.mem.eql(u8, eb.nullTerminatedString(eb.getErrorMessage(mi).msg), "found compile log statement")) return mi;
    }
    for (messages) |mi| {
        const src_loc = eb.getErrorMessage(mi).src_loc;
        if (src_loc == .none) continue;
        const path = try absolute(a, build_root, eb.nullTerminatedString(eb.getSourceLocation(src_loc).src_path)) orelse continue;
        if (Vfs.isUnderStyle(.native, .native, path, build_root)) return mi;
    }
    return messages[0];
}

/// Line diffs of text pairs computed during one `merge` or one `combine`, grouped by the path of
/// the file the texts belong to. A diff depends only on the two texts and is reused only when both
/// compare equal, so the result is the same as diffing every time. Entries are kept for the rest
/// of the operation: the notes of every error point into the same few files, and each build result
/// holds the text its own build read.
pub const Diffs = struct {
    a: Allocator,
    by_path: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Entry)) = .empty,

    const Entry = struct {
        /// Text the ranges of a diagnostic refer to
        from: []const u8,
        /// Text the ranges are shifted onto
        to: []const u8,
        edits: []const Edit,
    };

    /// Edits that shift a range of `from` onto `to`; empty when the texts are equal. The texts and
    /// the path must outlive the cache.
    pub fn get(d: *Diffs, path: []const u8, from: []const u8, to: []const u8) Allocator.Error![]const Edit {
        if (equal(from, to)) return &.{};
        const gop = try d.by_path.getOrPut(d.a, path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |e| {
            if (equal(e.from, from) and equal(e.to, to)) return e.edits;
        }
        const edits = try line_diff.diff(d.a, from, to);
        try gop.value_ptr.append(d.a, .{ .from = from, .to = to, .edits = edits });
        return edits;
    }

    /// Whether two texts are equal; equal slices are not read, since a note into the file being
    /// published holds the same texts as the diff `merge` computes for the file itself.
    fn equal(x: []const u8, y: []const u8) bool {
        return (x.ptr == y.ptr and x.len == y.len) or std.mem.eql(u8, x, y);
    }
};

/// Whether two errors are the same error: same range, message and notes (the reference trace,
/// which differs between the compilations that reach the error, is not compared). Each note's
/// range refers to the text of its file that its own build read: a note of `y` read from another
/// text is shifted onto the text of `x`'s note before comparing.
fn sameError(diffs: *Diffs, x: Item, y: Item) Allocator.Error!bool {
    if (x.start != y.start or x.end != y.end or !std.mem.eql(u8, x.message, y.message)) return false;
    if (x.note_count != y.note_count) return false;
    for (x.notes[0..x.note_count], y.notes[0..y.note_count]) |m, n| {
        if (!std.mem.eql(u8, m.path, n.path) or !std.mem.eql(u8, m.message, n.message)) return false;
        var start = n.start;
        var end = n.end;
        if (m.base_text) |mb| if (n.base_text) |nb| {
            const span = remap(try diffs.get(m.path, nb, mb), n.start, n.end) orelse return false;
            start = span[0];
            end = span[1];
        };
        if (m.start != start or m.end != end) return false;
    }
    return true;
}

/// Byte range of a source location. The values come from the error bundle sent back by the child
/// process and are not validated: an end before the start becomes an empty range at the start, so
/// a published Range is never reversed.
fn byteSpan(loc: ErrorBundle.SourceLocation) [2]u32 {
    return .{ loc.span_start, @max(loc.span_start, loc.span_end) };
}

/// Absolute path of `path` resolved relative to `base`. The result is interned into the Vfs as a
/// file and must be an absolute path; `path` comes from the error bundle sent back by the child
/// process and its contents are not validated, so null is returned when it does not resolve to an
/// absolute path (e.g. in a malformed bundle the path index may point into the middle of a source
/// line, at `x: u32 = 1;`, which on Windows is a path relative to another drive).
fn absolute(a: Allocator, base: []const u8, path: []const u8) Allocator.Error!?[]const u8 {
    return Vfs.resolve(.native, a, base, path);
}

/// Combines the results of several compilations of the same file (the builds of each project
/// containing it, and in single-file mode the compilations of each root file that imports it).
/// `results` is ordered by compile completion, newest first, and the most recently read text is
/// authoritative: results with the same text are merged as is; for results with a different text
/// (the file was modified between the two compilations), only non-AstGen errors are merged,
/// shifted according to the text diff, and those falling inside a modified region are dropped,
/// the same way `merge` handles unsaved changes. The same error (see `sameError`) is kept only
/// once (the compile log is merged into the kept one).
pub fn combine(arena: Allocator, results: []const *const FileResult) Allocator.Error!FileResult {
    const base = results[0].base_text;
    var items: std.ArrayList(Item) = .empty;
    var diffs: Diffs = .{ .a = arena };
    for (results) |r| {
        const edits: []const Edit = if (std.mem.eql(u8, r.base_text, base)) &.{} else try line_diff.diff(arena, r.base_text, base);
        next: for (r.items) |item| {
            var moved = item;
            if (edits.len != 0) {
                if (item.is_astgen) continue;
                const span = remap(edits, item.start, item.end) orelse continue;
                moved.start = span[0];
                moved.end = span[1];
            }
            for (items.items) |*x| {
                if (try sameError(&diffs, x.*, moved)) {
                    try addCompileLog(arena, x, moved.compile_log);
                    continue :next;
                }
            }
            try items.append(arena, moved);
        }
    }
    return .{ .base_text = base, .items = items.items };
}

// ── Merging ───────────────────────────────────────────────────────

pub const MergeInput = struct {
    /// Absolute path of the file the diagnostics belong to: the key of its diff with the build text
    path: []const u8,
    /// Current buffer text
    text: []const u8,
    lines: offsets.LineIndex,
    encoding: offsets.Encoding,
    uri: []const u8,
    /// Live diagnostics; null when the file gets none (see `Workspace.liveEligible`)
    live: ?*const live.Result,
    /// Compiler diagnostics of this file from the latest build
    compiler: ?*const FileResult,
    /// Used to compute the position and URI of notes located in other files
    other_file: OtherFileFn,
    other_ctx: *anyopaque,
};

pub const OtherFile = struct {
    uri: []const u8,
    text: []const u8,
    /// The line table of `text` when one is at hand; otherwise it is built for each note
    line_starts: ?[]const u32 = null,
};

/// Returns the URI and text of another file (for note positions); null when the file cannot be
/// read
pub const OtherFileFn = *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8) ?OtherFile;

pub fn merge(arena: Allocator, in: MergeInput) Allocator.Error![]const types.Diagnostic {
    var out: std.ArrayList(types.Diagnostic) = .empty;
    // The diff of the build text and the buffer is kept for the notes that point into this file
    var diffs: Diffs = .{ .a = arena };
    if (in.compiler) |c| {
        if (std.mem.eql(u8, c.base_text, in.text)) {
            // The buffer matches the build: compiler diagnostics already include AstGen errors
            for (c.items) |item| try out.append(arena, try compilerDiagnostic(arena, in, &diffs, item, item.start, item.end));
            return out.items;
        }
    }
    if (in.live) |l| {
        for (l.items) |d| try out.append(arena, try liveDiagnostic(arena, in, d));
    }
    if (in.compiler) |c| {
        // Unsaved changes: the compiler's non-AstGen errors are shifted according to the text
        // diff, and those inside a modified region are hidden. The `@compileLog` output of a
        // hidden error is still the latest output of the build: it is published on its own, at
        // the error's start (the start of the modified region that hides it).
        const edits = try diffs.get(in.path, c.base_text, in.text);
        for (c.items) |item| {
            if (!item.is_astgen) if (remap(edits, item.start, item.end)) |span| {
                try out.append(arena, try compilerDiagnostic(arena, in, &diffs, item, span[0], span[1]));
                continue;
            };
            if (item.compile_log.len == 0) continue;
            const at = remapPoint(edits, item.start, in.text.len);
            try out.append(arena, .{
                .range = in.lines.range(at, at, in.encoding),
                .severity = .Information,
                .source = "zig",
                .message = .{ .string = try std.fmt.allocPrint(arena, "Compile Log Output:\n{s}", .{item.compile_log}) },
            });
        }
    }
    return out.items;
}

/// A range entirely before the modified regions stays unchanged, one entirely after them is
/// shifted by the length difference, and one that intersects any modified region yields null. A
/// range may cross a `line_break` edit: its start and end are shifted separately, and only a start
/// or end inside the line terminator yields null. Ranges from the compiler are not necessarily
/// valid (end before start, far beyond the text): a range that exceeds u32 after shifting also
/// yields null. The diff is in whole lines: modifying a line hides the diagnostics on that line
/// without affecting unmodified lines.
fn remap(edits: []const Edit, start: u32, end: u32) ?[2]u32 {
    var start_delta: i64 = 0;
    var end_delta: i64 = 0;
    for (edits) |e| {
        if (end <= e.start) break;
        const delta = @as(i64, e.new_end) - @as(i64, e.old_end);
        if (e.line_break) {
            if (start > e.start and start < e.old_end) return null;
            if (end < e.old_end) return null;
            if (start >= e.old_end) start_delta = delta;
        } else {
            if (start < e.old_end) return null;
            start_delta = delta;
        }
        end_delta = delta;
    }
    const shifted_start = std.math.cast(u32, @as(i64, start) + start_delta) orelse return null;
    const shifted_end = std.math.cast(u32, @as(i64, end) + end_delta) orelse return null;
    return .{ shifted_start, shifted_end };
}

/// Offset in the new text of the old text's offset `pos`: shifted like `remap` when it is
/// outside the modified regions, the start of the region otherwise; at most `len` (the length of
/// the new text), as offsets from the compiler are not necessarily valid
fn remapPoint(edits: []const Edit, pos: u32, len: usize) u32 {
    var delta: i64 = 0;
    const shifted: i64 = for (edits) |e| {
        if (pos < e.start) break @as(i64, pos) + delta;
        if (pos < e.old_end) break @as(i64, e.start) + delta;
        delta = @as(i64, e.new_end) - @as(i64, e.old_end);
    } else @as(i64, pos) + delta;
    return @intCast(std.math.clamp(shifted, 0, @as(i64, @intCast(@min(len, std.math.maxInt(u32))))));
}

// Messages are copied into `arena`: live results belong to the `AstCheck` memo and compile
// results belong to the workspace (freed when a new build result arrives), while publishing
// serializes only after the read transaction ends and the workspace lock is released; either may
// be freed in the meantime
fn liveDiagnostic(arena: Allocator, in: MergeInput, d: live.Diagnostic) Allocator.Error!types.Diagnostic {
    const related = try arena.alloc(types.DiagnosticRelatedInformation, d.notes.len);
    for (d.notes, related) |n, *r| r.* = .{
        .location = .{ .uri = in.uri, .range = in.lines.range(n.start, n.end, in.encoding) },
        .message = try arena.dupe(u8, n.message),
    };
    return .{
        .range = in.lines.range(d.start, d.end, in.encoding),
        .severity = .Error,
        .source = "zig ast-check",
        .message = .{ .string = try arena.dupe(u8, d.message) },
        .relatedInformation = if (related.len == 0) null else related,
    };
}

fn compilerDiagnostic(arena: Allocator, in: MergeInput, diffs: *Diffs, item: Item, start: u32, end: u32) Allocator.Error!types.Diagnostic {
    var related: std.ArrayList(types.DiagnosticRelatedInformation) = .empty;
    for (item.notes) |n| {
        const other = in.other_file(in.other_ctx, arena, n.path) orelse continue;
        const lines: offsets.LineIndex = if (other.line_starts) |s| .{ .text = other.text, .line_starts = s } else try offsets.LineIndex.init(arena, other.text);
        // The note's file changed since the note's build (unsaved changes, or a newer build of
        // the file): shift by the diff from the text that build read
        var note_start = n.start;
        var note_end = n.end;
        if (n.base_text) |base| {
            const span = remap(try diffs.get(n.path, base, other.text), n.start, n.end) orelse continue;
            note_start = span[0];
            note_end = span[1];
        }
        try related.append(arena, .{
            .location = .{ .uri = other.uri, .range = lines.range(note_start, note_end, in.encoding) },
            .message = try arena.dupe(u8, n.message),
        });
    }
    const message = if (item.compile_log.len == 0)
        try arena.dupe(u8, item.message)
    else
        try std.fmt.allocPrint(arena, "{s}\n\nCompile Log Output:\n{s}", .{ item.message, item.compile_log });
    return .{
        .range = in.lines.range(start, end, in.encoding),
        .severity = .Error,
        .source = "zig",
        .message = .{ .string = message },
        .relatedInformation = if (related.items.len == 0) null else related.items,
    };
}

test {
    _ = @import("compiler_test.zig");
}
