//! `compiler` diagnostic source: converts the ErrorBundles in build results into per-file
//! diagnostics and merges them with live diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const live = @import("live.zig");
const Vfs = @import("../base/Vfs.zig");

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
pub fn collect(
    gpa: Allocator,
    bundles: []const ErrorBundle,
    build_root: []const u8,
    fallback_path: []const u8,
    read_ctx: *anyopaque,
    read: ReadFn,
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
        // Mark AstGen errors: run AstGen on the same text and match by range and message
        const mode = live.modeOf(path);
        const astgen = try live.check(gpa, text, mode);
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

/// Whether two errors are the same error: same range, message and notes (the reference trace,
/// which differs between the compilations that reach the error, is not compared). Each note's
/// range refers to the text of its file that its own build read: a note of `y` read from another
/// text is shifted onto the text of `x`'s note before comparing.
fn sameError(arena: Allocator, x: Item, y: Item) Allocator.Error!bool {
    if (x.start != y.start or x.end != y.end or !std.mem.eql(u8, x.message, y.message)) return false;
    if (x.note_count != y.note_count) return false;
    for (x.notes[0..x.note_count], y.notes[0..y.note_count]) |m, n| {
        if (!std.mem.eql(u8, m.path, n.path) or !std.mem.eql(u8, m.message, n.message)) return false;
        var start = n.start;
        var end = n.end;
        if (m.base_text) |mb| if (n.base_text) |nb| if (!std.mem.eql(u8, mb, nb)) {
            start, end = remap(try diffEdits(arena, nb, mb), n.start, n.end) orelse return false;
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
    for (results) |r| {
        const edits: []const Edit = if (std.mem.eql(u8, r.base_text, base)) &.{} else try diffEdits(arena, r.base_text, base);
        next: for (r.items) |item| {
            var moved = item;
            if (edits.len != 0) {
                if (item.is_astgen) continue;
                const span = remap(edits, item.start, item.end) orelse continue;
                moved.start = span[0];
                moved.end = span[1];
            }
            for (items.items) |*x| {
                if (try sameError(arena, x.*, moved)) {
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

pub const OtherFile = struct { uri: []const u8, text: []const u8 };

/// Returns the URI and text of another file (for note positions); null when the file cannot be
/// read
pub const OtherFileFn = *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8) ?OtherFile;

pub fn merge(arena: Allocator, in: MergeInput) Allocator.Error![]const types.Diagnostic {
    var out: std.ArrayList(types.Diagnostic) = .empty;
    if (in.compiler) |c| {
        if (std.mem.eql(u8, c.base_text, in.text)) {
            // The buffer matches the build: compiler diagnostics already include AstGen errors
            for (c.items) |item| try out.append(arena, try compilerDiagnostic(arena, in, item, item.start, item.end));
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
        const edits = try diffEdits(arena, c.base_text, in.text);
        for (c.items) |item| {
            if (!item.is_astgen) if (remap(edits, item.start, item.end)) |span| {
                try out.append(arena, try compilerDiagnostic(arena, in, item, span[0], span[1]));
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

/// A differing range between the old and new text: old text [start, old_end) is replaced by the
/// new text that ends at `new_end`. `old_end` and `new_end` are offsets in their own text, so
/// `new_end - old_end` is the total shift of everything after this range, including the length
/// differences of the ranges before it.
const Edit = struct {
    start: u32,
    old_end: u32,
    new_end: u32,
    /// Only the line terminator differs (`\r\n` and `\n`): the lines on both sides are the same
    line_break: bool = false,
};

/// A line of a text: its content [start, end) and the start of the next line; the line terminator
/// lies in between
const Line = struct { start: u32, end: u32, next: u32 };

/// Line `old` of the old text matched with the identical line `new` of the new text
const Match = struct {
    old: usize,
    new: usize,

    fn before(_: void, a: Match, b: Match) bool {
        return a.old < b.old;
    }
};

/// Compares the old and new text line by line (a patience diff) and returns disjoint replacement
/// ranges sorted by position. Lines are compared without their terminator (`\r\n` and `\n` are
/// equivalent, as for the compiler); identical lines whose terminators differ yield a `line_break`
/// edit. In each range of lines still to compare, identical lines at its start and end are
/// matched; of the remaining lines, those identical and unique on both sides within the range are
/// matched along their longest increasing subsequence, and the ranges between them are compared
/// the same way. Lines left without a match form the modified regions, so no region starts or ends
/// with a line that is identical on both sides. Line granularity is conservative: modifying a line
/// hides the diagnostics on that line without affecting unmodified lines.
fn diffEdits(a: Allocator, old: []const u8, new: []const u8) Allocator.Error![]const Edit {
    if (std.mem.eql(u8, old, new)) return &.{};
    const old_lines = try splitLines(a, old);
    const new_lines = try splitLines(a, new);
    const Range = struct { old_start: usize, old_end: usize, new_start: usize, new_end: usize };
    // Occurrences of a line in the range on each side, and the old line it first occurs on
    const Count = struct { old: usize, new: usize, old_line: usize };
    var matches: std.ArrayList(Match) = .empty;
    var pending: std.ArrayList(Range) = .empty;
    var counts: std.StringHashMapUnmanaged(Count) = .empty;
    var unique: std.ArrayList(Match) = .empty;
    try pending.append(a, .{ .old_start = 0, .old_end = old_lines.len, .new_start = 0, .new_end = new_lines.len });
    while (pending.pop()) |range| {
        var r = range;
        while (r.old_start < r.old_end and r.new_start < r.new_end and
            std.mem.eql(u8, lineText(old, old_lines, r.old_start), lineText(new, new_lines, r.new_start)))
        {
            try matches.append(a, .{ .old = r.old_start, .new = r.new_start });
            r.old_start += 1;
            r.new_start += 1;
        }
        while (r.old_start < r.old_end and r.new_start < r.new_end and
            std.mem.eql(u8, lineText(old, old_lines, r.old_end - 1), lineText(new, new_lines, r.new_end - 1)))
        {
            r.old_end -= 1;
            r.new_end -= 1;
            try matches.append(a, .{ .old = r.old_end, .new = r.new_end });
        }
        counts.clearRetainingCapacity();
        for (r.old_start..r.old_end) |i| {
            const gop = try counts.getOrPut(a, lineText(old, old_lines, i));
            if (gop.found_existing) gop.value_ptr.old += 1 else gop.value_ptr.* = .{ .old = 1, .new = 0, .old_line = i };
        }
        for (r.new_start..r.new_end) |i| {
            if (counts.getPtr(lineText(new, new_lines, i))) |c| c.new += 1;
        }
        unique.clearRetainingCapacity();
        for (r.new_start..r.new_end) |i| {
            const c = counts.get(lineText(new, new_lines, i)) orelse continue;
            if (c.old == 1 and c.new == 1) try unique.append(a, .{ .old = c.old_line, .new = i });
        }
        const anchors = try longestIncreasing(a, unique.items);
        if (anchors.len == 0) continue;
        var old_start = r.old_start;
        var new_start = r.new_start;
        for (anchors) |m| {
            try matches.append(a, m);
            try pending.append(a, .{ .old_start = old_start, .old_end = m.old, .new_start = new_start, .new_end = m.new });
            old_start = m.old + 1;
            new_start = m.new + 1;
        }
        try pending.append(a, .{ .old_start = old_start, .old_end = r.old_end, .new_start = new_start, .new_end = r.new_end });
    }
    std.mem.sort(Match, matches.items, {}, Match.before);
    var edits: std.ArrayList(Edit) = .empty;
    var oi: usize = 0;
    var ni: usize = 0;
    for (matches.items) |m| {
        try addEdit(a, &edits, old, new, old_lines, new_lines, oi, m.old, ni, m.new);
        const ol = old_lines[m.old];
        const nl = new_lines[m.new];
        if (!std.mem.eql(u8, old[ol.end..ol.next], new[nl.end..nl.next])) {
            try edits.append(a, .{ .start = ol.end, .old_end = ol.next, .new_end = nl.next, .line_break = true });
        }
        oi = m.old + 1;
        ni = m.new + 1;
    }
    try addEdit(a, &edits, old, new, old_lines, new_lines, oi, old_lines.len, ni, new_lines.len);
    return edits.items;
}

fn splitLines(a: Allocator, text: []const u8) Allocator.Error![]const Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const next = if (nl) |i| i + 1 else text.len;
        const end = if (nl) |i| if (i > start and text[i - 1] == '\r') i - 1 else i else text.len;
        try lines.append(a, .{ .start = @intCast(start), .end = @intCast(end), .next = @intCast(next) });
        start = next;
    }
    return lines.items;
}

fn lineText(text: []const u8, lines: []const Line, i: usize) []const u8 {
    return text[lines[i].start..lines[i].end];
}

fn lineOffset(lines: []const Line, text: []const u8, i: usize) u32 {
    return @intCast(if (i < lines.len) lines[i].start else text.len);
}

fn addEdit(
    a: Allocator,
    edits: *std.ArrayList(Edit),
    old: []const u8,
    new: []const u8,
    old_lines: []const Line,
    new_lines: []const Line,
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
) Allocator.Error!void {
    const os = lineOffset(old_lines, old, old_start);
    const oe = lineOffset(old_lines, old, old_end);
    const ns = lineOffset(new_lines, new, new_start);
    const ne = lineOffset(new_lines, new, new_end);
    if (os == oe and ns == ne) return;
    try edits.append(a, .{ .start = os, .old_end = oe, .new_end = ne });
}

/// `pairs` is sorted by increasing `new`; returns the longest subsequence with strictly increasing
/// `old`
fn longestIncreasing(a: Allocator, pairs: []const Match) Allocator.Error![]const Match {
    if (pairs.len == 0) return &.{};
    const tails = try a.alloc(usize, pairs.len);
    const prev = try a.alloc(?usize, pairs.len);
    var len: usize = 0;
    for (pairs, 0..) |p, i| {
        var lo: usize = 0;
        var hi: usize = len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (pairs[tails[mid]].old < p.old) lo = mid + 1 else hi = mid;
        }
        prev[i] = if (lo > 0) tails[lo - 1] else null;
        tails[lo] = i;
        if (lo == len) len += 1;
    }
    const out = try a.alloc(Match, len);
    var k: ?usize = if (len > 0) tails[len - 1] else null;
    var i: usize = len;
    while (k) |x| : (k = prev[x]) {
        i -= 1;
        out[i] = pairs[x];
    }
    return out;
}

/// A range entirely before the modified regions stays unchanged, one entirely after them is
/// shifted by the length difference, and one that intersects any modified region yields null. A
/// range may cross a `line_break` edit: its start and end are shifted separately, and only a start
/// or end inside the line terminator yields null. Ranges from the compiler are not necessarily
/// valid (end before start, far beyond the text): a range that exceeds u32 after shifting also
/// yields null.
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

fn compilerDiagnostic(arena: Allocator, in: MergeInput, item: Item, start: u32, end: u32) Allocator.Error!types.Diagnostic {
    var related: std.ArrayList(types.DiagnosticRelatedInformation) = .empty;
    for (item.notes) |n| {
        const other = in.other_file(in.other_ctx, arena, n.path) orelse continue;
        const lines = try offsets.LineIndex.init(arena, other.text);
        // The note's file changed since the note's build (unsaved changes, or a newer build of
        // the file): shift by the diff from the text that build read
        var note_start = n.start;
        var note_end = n.end;
        if (n.base_text) |base| if (!std.mem.eql(u8, base, other.text)) {
            const edits = try diffEdits(arena, base, other.text);
            const span = remap(edits, n.start, n.end) orelse continue;
            note_start = span[0];
            note_end = span[1];
        };
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
