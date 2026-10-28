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
    notes: []const Note,
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
    /// Texts read during the build: each file in `files`, plus files that notes point to but that
    /// have no errors (looked up by path)
    texts: std.StringArrayHashMapUnmanaged([]const u8),
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
/// as link errors) are attached to the start of `fallback_path` (usually build.zig).
/// When `src_path` does not resolve to an absolute path (a malformed error bundle, see
/// `absolute`), it is treated as having no location: the error is attached to the start of
/// `fallback_path`, and the notes and reference trace are placed at the start of the error.
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

    var lists: std.StringArrayHashMapUnmanaged(std.ArrayList(Item)) = .empty;
    // Dedup: several compile steps may report the same error in the same file. The value is the
    // index of the kept error in that file's list.
    var seen: std.StringHashMapUnmanaged(usize) = .empty;

    for (bundles) |eb| {
        if (eb.errorMessageCount() == 0) continue;
        const log_text = try a.dupe(u8, std.mem.trimEnd(u8, eb.getCompileLogOutput(), "\n"));
        // The `@compileLog` output is attached to the "found compile log statement" error (or to
        // the first error when there is no such error)
        const log_target: ?ErrorBundle.MessageIndex = if (log_text.len == 0) null else for (eb.getMessages()) |mi| {
            if (std.mem.eql(u8, eb.nullTerminatedString(eb.getErrorMessage(mi).msg), "found compile log statement")) break mi;
        } else eb.getMessages()[0];
        for (eb.getMessages()) |mi| {
            const msg = eb.getErrorMessage(mi);
            const message = eb.nullTerminatedString(msg.msg);
            const compile_log = if (log_target == mi) log_text else "";
            var path: []const u8 = fallback_path;
            var start: u32 = 0;
            var end: u32 = 0;
            if (msg.src_loc != .none) {
                const loc = eb.getSourceLocation(msg.src_loc);
                if (try absolute(a, build_root, eb.nullTerminatedString(loc.src_path))) |p| {
                    path = p;
                    start, end = byteSpan(loc);
                }
            }
            const key = try std.fmt.allocPrint(a, "{s}\x00{d}\x00{d}\x00{s}", .{ path, start, end, message });
            const seen_gop = try seen.getOrPut(a, key);
            if (seen_gop.found_existing) {
                try addCompileLog(a, &lists.getPtr(path).?.items[seen_gop.value_ptr.*], compile_log);
                continue;
            }

            // The notes are followed by the reference trace
            const refs: u32 = if (msg.src_loc != .none) eb.getSourceLocation(msg.src_loc).reference_trace_len else 0;
            const notes = try a.alloc(Note, msg.notes_len + refs);
            for (notes[0..msg.notes_len], eb.getNotes(mi)) |*note, ni| {
                const n = eb.getErrorMessage(ni);
                note.* = .{ .path = path, .start = start, .end = start, .message = try a.dupe(u8, eb.nullTerminatedString(n.msg)) };
                if (n.src_loc != .none) {
                    const nl = eb.getSourceLocation(n.src_loc);
                    if (try absolute(a, build_root, eb.nullTerminatedString(nl.src_path))) |p| {
                        note.path = p;
                        note.start, note.end = byteSpan(nl);
                    }
                }
            }
            if (refs != 0) try referenceTrace(a, eb, msg.src_loc, build_root, path, start, notes[msg.notes_len..]);
            const gop = try lists.getOrPut(a, path);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            seen_gop.value_ptr.* = gop.value_ptr.items.len;
            try gop.value_ptr.append(a, .{ .start = start, .end = end, .message = try a.dupe(u8, message), .is_astgen = false, .notes = notes, .compile_log = compile_log });
        }
    }

    var files: std.StringArrayHashMapUnmanaged(FileResult) = .empty;
    // A file that notes point to is not in `files` when it has no errors of its own; its
    // build-time text is saved as well, for shifting the notes
    var texts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (lists.values()) |items| for (items.items) |item| for (item.notes) |n| {
        if (texts.contains(n.path)) continue;
        const text = read(read_ctx, a, n.path) orelse continue;
        try texts.put(a, n.path, text);
    };
    for (lists.keys(), lists.values()) |path, *items| {
        const text = texts.get(path) orelse blk: {
            const t = read(read_ctx, a, path) orelse "";
            try texts.put(a, path, t);
            break :blk t;
        };
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
    result.* = .{ .arena = undefined, .files = files, .texts = texts };
    // Take the arena state after the last allocation
    result.arena = arena_state.state;
    return result;
}

/// Converts the reference trace following source location `src_loc` into notes, with messages
/// matching the output of `zig build`. A reference with a location points to the referencing
/// site; the trailing hidden marker has no location and, like notes without a location, is
/// placed at the start of the error (`start` in `path`).
fn referenceTrace(a: Allocator, eb: ErrorBundle, src_loc: ErrorBundle.SourceLocationIndex, build_root: []const u8, path: []const u8, start: u32, out: []Note) Allocator.Error!void {
    // ErrorBundle has no public interface for reading the reference trace: it is read from
    // `extra` according to its layout. `SourceLocation` is followed by the `ReferenceTrace`s one
    // after another, each storing `decl_name` and `src_loc` in field order.
    const first = @backingInt(src_loc) + @typeInfo(ErrorBundle.SourceLocation).@"struct".field_names.len;
    const stride = @typeInfo(ErrorBundle.ReferenceTrace).@"struct".field_names.len;
    for (out, 0..) |*note, k| {
        const at = first + k * stride;
        const decl_name: ErrorBundle.String = eb.extra[at];
        const ref_loc: ErrorBundle.SourceLocationIndex = @fromBackingInt(eb.extra[at + 1]);
        note.* = .{ .path = path, .start = start, .end = start, .message = "" };
        if (ref_loc != .none) {
            const rl = eb.getSourceLocation(ref_loc);
            if (try absolute(a, build_root, eb.nullTerminatedString(rl.src_path))) |p| {
                note.path = p;
                note.start, note.end = byteSpan(rl);
            }
            note.message = try std.fmt.allocPrint(a, "referenced by: {s}", .{eb.nullTerminatedString(decl_name)});
        } else if (decl_name != 0) {
            // Hidden marker: `decl_name` is the number of hidden references
            note.message = try std.fmt.allocPrint(a, "{d} reference(s) hidden; use '-freference-trace={d}' to see all references", .{ decl_name, decl_name + out.len - 1 });
        } else {
            note.message = "remaining reference traces hidden; use '-freference-trace' to see all reference traces";
        }
    }
}

/// When only one of several duplicate errors is kept, the compile log of a dropped one is merged
/// into the kept one (identical logs are kept only once)
fn addCompileLog(a: Allocator, item: *Item, compile_log: []const u8) Allocator.Error!void {
    if (compile_log.len == 0 or std.mem.eql(u8, item.compile_log, compile_log)) return;
    item.compile_log = if (item.compile_log.len == 0) compile_log else try std.mem.join(a, "\n", &.{ item.compile_log, compile_log });
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
/// the same way `merge` handles unsaved changes. Errors with the same range and message are kept
/// only once (the compile log is merged into the kept one).
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
                if (x.start == moved.start and x.end == moved.end and std.mem.eql(u8, x.message, moved.message)) {
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
    /// Live diagnostics; null when the file is not in the compile set
    live: ?*const live.Result,
    /// Compiler diagnostics of this file from the latest build
    compiler: ?*const FileResult,
    /// Used to compute the position and URI of notes located in other files
    other_file: OtherFileFn,
    other_ctx: *anyopaque,
};

pub const OtherFile = struct { uri: []const u8, text: []const u8, base_text: ?[]const u8 = null };

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
        // diff, and those inside a modified region are hidden
        const edits = try diffEdits(arena, c.base_text, in.text);
        for (c.items) |item| {
            if (item.is_astgen) continue;
            const span = remap(edits, item.start, item.end) orelse continue;
            try out.append(arena, try compilerDiagnostic(arena, in, item, span[0], span[1]));
        }
    }
    return out.items;
}

/// A differing range between the old and new text: old text [start, old_end) is replaced by new
/// text [start, new_end)
const Edit = struct { start: u32, old_end: u32, new_end: u32 };

const Line = struct { start: u32, end: u32 };

/// Line anchor: a line with identical content that is unique on both sides
const Anchor = struct { old: usize, new: usize };

/// Compares the old and new text line by line and returns disjoint replacement ranges sorted by
/// position. Identical lines that are unique on both sides serve as anchors, and the lines between
/// the anchors of their longest increasing subsequence are treated as modified regions as a whole.
/// Line granularity is conservative: modifying a line hides the diagnostics on that line without
/// affecting unmodified lines.
fn diffEdits(a: Allocator, old: []const u8, new: []const u8) Allocator.Error![]const Edit {
    if (std.mem.eql(u8, old, new)) return &.{};
    const old_lines = try splitLines(a, old);
    const new_lines = try splitLines(a, new);
    var old_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (old_lines) |l| {
        const gop = try old_counts.getOrPut(a, old[l.start..l.end]);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var new_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (new_lines) |l| {
        const gop = try new_counts.getOrPut(a, new[l.start..l.end]);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var old_unique: std.StringHashMapUnmanaged(usize) = .empty;
    for (old_lines, 0..) |l, i| {
        const line = old[l.start..l.end];
        if (old_counts.get(line).? == 1) try old_unique.put(a, line, i);
    }
    var pairs: std.ArrayList(Anchor) = .empty;
    for (new_lines, 0..) |l, i| {
        const line = new[l.start..l.end];
        if (new_counts.get(line).? != 1) continue;
        const oi = old_unique.get(line) orelse continue;
        try pairs.append(a, .{ .old = oi, .new = i });
    }
    const anchors = try longestIncreasing(a, pairs.items);
    var edits: std.ArrayList(Edit) = .empty;
    var oi: usize = 0;
    var ni: usize = 0;
    for (anchors) |an| {
        try addEdit(a, &edits, old, new, old_lines, new_lines, oi, an.old, ni, an.new);
        oi = an.old + 1;
        ni = an.new + 1;
    }
    try addEdit(a, &edits, old, new, old_lines, new_lines, oi, old_lines.len, ni, new_lines.len);
    return edits.items;
}

fn splitLines(a: Allocator, text: []const u8) Allocator.Error![]const Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = if (nl) |i| i + 1 else text.len;
        try lines.append(a, .{ .start = @intCast(start), .end = @intCast(end) });
        start = end;
    }
    return lines.items;
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
fn longestIncreasing(a: Allocator, pairs: []const Anchor) Allocator.Error![]const Anchor {
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
    const out = try a.alloc(Anchor, len);
    var k: ?usize = if (len > 0) tails[len - 1] else null;
    var i: usize = len;
    while (k) |x| : (k = prev[x]) {
        i -= 1;
        out[i] = pairs[x];
    }
    return out;
}

/// A range entirely before the modified regions stays unchanged, one entirely after them is
/// shifted by the length difference, and one that intersects any modified region yields null.
/// Ranges from the compiler are not necessarily valid (end before start, far beyond the text): a
/// range that exceeds u32 after shifting also yields null.
fn remap(edits: []const Edit, start: u32, end: u32) ?[2]u32 {
    var delta: i64 = 0;
    for (edits) |e| {
        if (end <= e.start) break;
        if (start < e.old_end) return null;
        delta += @as(i64, e.new_end) - @as(i64, e.old_end);
    }
    const shifted_start = std.math.cast(u32, @as(i64, start) + delta) orelse return null;
    const shifted_end = std.math.cast(u32, @as(i64, end) + delta) orelse return null;
    return .{ shifted_start, shifted_end };
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
        // The note's file also has unsaved changes since the build: shift by that file's own diff
        var note_start = n.start;
        var note_end = n.end;
        if (other.base_text) |base| if (!std.mem.eql(u8, base, other.text)) {
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
