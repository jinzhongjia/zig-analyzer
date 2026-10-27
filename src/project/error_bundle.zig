//! Validates the `std.zig.ErrorBundle` sent back by child processes.
//!
//! The ErrorBundle format has no version number: when the user's zig and the zig that
//! zig-analyzer was compiled with are different versions, a single-file compile reads data
//! produced by a different version of the compiler. Neither the standard library's read
//! functions (`getErrorMessage`, `getNotes`, `nullTerminatedString`, etc.) nor
//! `diagnostics/compiler.zig`, which reads reference traces by layout, check indices, so a
//! mismatched format causes out-of-bounds reads; the bundle is therefore validated before use.

const std = @import("std");
const ErrorBundle = std.zig.ErrorBundle;

const list_words = fieldCount(ErrorBundle.ErrorMessageList);
const message_words = fieldCount(ErrorBundle.ErrorMessage);
const location_words = fieldCount(ErrorBundle.SourceLocation);
const trace_words = fieldCount(ErrorBundle.ReferenceTrace);

/// Maximum nesting depth of notes and of locations in reference traces, which bounds the
/// recursion of the validation: self-references and cycles both exceed it.
/// Notes produced by the compiler are only one level deep, and locations in reference traces do
/// not carry reference traces of their own
const max_depth = 32;

/// The limit on the total amount read, as a multiple of `extra.len`. In an error bundle built by
/// the standard library, structures do not overlap and are each referenced only once, so the
/// total read does not exceed `extra.len`; error bundles that share structures still pass, while
/// many references to the same structure (the amount read grows exponentially with nesting
/// depth) are rejected
const max_reads_per_word = 4;

/// Whether everything in `eb` that this project and the standard library functions it calls read
/// is in bounds:
/// - The message list, each message and its notes at every level, and each source location with
///   the reference trace that follows it are within `extra`;
/// - The indices of messages, paths, source lines, reference names, and the compile log all
///   point to 0-terminated strings in `string_bytes`;
/// - For reference trace entries without a location (hidden markers), `decl_name` is the number
///   of hidden references rather than a string, and adding the reference trace length to it does
///   not overflow u32.
///
/// Numeric values such as line/column, span, and `count` are not checked; consumers must cope
/// with arbitrary values. An empty error bundle (empty `extra`) is valid.
pub fn isValid(eb: ErrorBundle) bool {
    if (eb.extra.len == 0) return true;
    // Indices are all u32: the standard library and `diagnostics/compiler.zig` compute the
    // position after a structure in u32
    if (eb.extra.len > std.math.maxInt(u32)) return false;
    var v: Validator = .{
        .eb = eb,
        .last_nul = std.mem.lastIndexOfScalar(u8, eb.string_bytes, 0),
        .budget = @as(u64, eb.extra.len) * max_reads_per_word,
    };
    if (!v.take(0, list_words)) return false;
    const list = eb.getErrorMessageList();
    // `getCompileLogOutput` reads this string even when there is no output (index 0)
    if (!v.string(list.compile_log_text)) return false;
    if (!v.take(list.start, list.len)) return false;
    for (eb.getMessages()) |mi| if (!v.message(@backingInt(mi), 0)) return false;
    return true;
}

const Validator = struct {
    eb: ErrorBundle,
    /// Position of the last 0 in `string_bytes`: for a string index not beyond it, reading
    /// forward from the index is guaranteed to reach a terminator
    last_nul: ?usize,
    /// Number of `extra` words that may still be read
    budget: u64,

    /// Reads `extra[index..][0..len]`: must be in bounds and within the total read limit
    fn take(v: *Validator, index: u64, len: u64) bool {
        if (index + len > v.eb.extra.len or len > v.budget) return false;
        v.budget -= len;
        return true;
    }

    fn string(v: *const Validator, index: ErrorBundle.String) bool {
        const last = v.last_nul orelse return false;
        return index <= last;
    }

    /// A message and its notes. Notes are messages too; the standard library recurses through
    /// them level by level when rendering
    fn message(v: *Validator, index: u32, depth: u32) bool {
        if (depth > max_depth or !v.take(index, message_words)) return false;
        const mi: ErrorBundle.MessageIndex = @fromBackingInt(index);
        const msg = v.eb.getErrorMessage(mi);
        if (!v.string(msg.msg)) return false;
        if (msg.src_loc != .none and !v.location(@backingInt(msg.src_loc), depth + 1)) return false;
        if (!v.take(@as(u64, index) + message_words, msg.notes_len)) return false;
        for (v.eb.getNotes(mi)) |note| if (!v.message(@backingInt(note), depth + 1)) return false;
        return true;
    }

    /// A source location and the reference trace that follows it
    fn location(v: *Validator, index: u32, depth: u32) bool {
        if (depth > max_depth or !v.take(index, location_words)) return false;
        const loc = v.eb.getSourceLocation(@fromBackingInt(index));
        if (!v.string(loc.src_path)) return false;
        if (loc.source_line != 0 and !v.string(loc.source_line)) return false;
        const first = @as(u64, index) + location_words;
        if (!v.take(first, @as(u64, loc.reference_trace_len) * trace_words)) return false;
        // Each entry stores `decl_name` and `src_loc` in field order
        for (0..loc.reference_trace_len) |k| {
            const at: usize = @intCast(first + k * trace_words);
            const decl_name = v.eb.extra[at];
            const ref_loc = v.eb.extra[at + 1];
            if (ref_loc != @backingInt(ErrorBundle.SourceLocationIndex.none)) {
                if (!v.string(decl_name) or !v.location(ref_loc, depth + 1)) return false;
            } else if (decl_name != 0) {
                // Hidden marker: rendered as
                // `-freference-trace=<hidden count + reference trace length - 1>`, computed in u32
                // by adding first and then subtracting
                if (@as(u64, decl_name) + loc.reference_trace_len > std.math.maxInt(u32)) return false;
            }
        }
        return true;
    }
};

fn fieldCount(comptime T: type) comptime_int {
    return @typeInfo(T).@"struct".field_names.len;
}

const testing = std.testing;

/// A valid error bundle built with the standard library, and the indices in `extra` of the
/// structures in it
const Fixture = struct {
    eb: ErrorBundle,
    /// Message with a note, a source line, and a reference trace (one reference with a location,
    /// one hidden count)
    root: u32,
    err_loc: u32,
    /// Message without a location whose note has a note of its own
    chain: u32,
    nested: u32,

    fn init() !Fixture {
        const gpa = testing.allocator;
        var wip: ErrorBundle.Wip = try .init(gpa);
        defer wip.deinit();
        const ref_loc = try wip.addSourceLocation(.{
            .src_path = try wip.addString("caller.zig"),
            .line = 2,
            .column = 4,
            .span_start = 40,
            .span_main = 40,
            .span_end = 48,
            .source_line = try wip.addString("    m.main();"),
        });
        const note_loc = try wip.addSourceLocation(.{ .src_path = try wip.addString("main.zig"), .line = 3, .column = 8, .span_start = 50, .span_main = 50, .span_end = 51 });
        const err_loc = try wip.addSourceLocation(.{
            .src_path = try wip.addString("main.zig"),
            .line = 2,
            .column = 19,
            .span_start = 30,
            .span_main = 30,
            .span_end = 33,
            .source_line = try wip.addString("    const x: u32 = \"s\";"),
            .reference_trace_len = 2,
        });
        try wip.addReferenceTrace(.{ .decl_name = try wip.addString("f"), .src_loc = ref_loc });
        // The hidden count exceeds the length of `string_bytes`: validation fails if it is
        // mistaken for a string index
        try wip.addReferenceTrace(.{ .decl_name = 100000, .src_loc = .none });
        try wip.addRootErrorMessageWithNotes(
            .{ .msg = try wip.addString("expected type 'u32', found '*const [1:0]u8'"), .count = 2, .src_loc = err_loc, .notes_len = 1 },
            &.{.{ .msg = try wip.addString("a note"), .src_loc = note_loc }},
        );

        const unused_loc = try wip.addSourceLocation(.{ .src_path = try wip.addString("main.zig"), .line = 1, .column = 8, .span_start = 25, .span_main = 25, .span_end = 31, .reference_trace_len = 1 });
        try wip.addReferenceTrace(.{ .decl_name = 0, .src_loc = .none });
        try wip.addRootErrorMessage(.{ .msg = try wip.addString("unused local variable"), .src_loc = unused_loc });

        // A note of a note
        try wip.addRootErrorMessage(.{ .msg = try wip.addString("undefined symbol: foo"), .notes_len = 1 });
        const chain_notes = try wip.reserveNotes(1);
        const nested = try wip.addErrorMessage(.{ .msg = try wip.addString("referenced here"), .notes_len = 1 });
        const nested_notes = try wip.reserveNotes(1);
        const leaf = try wip.addErrorMessage(.{ .msg = try wip.addString("and here") });
        wip.extra.items[chain_notes] = @backingInt(nested);
        wip.extra.items[nested_notes] = @backingInt(leaf);

        const root = @backingInt(wip.root_list.items[0]);
        const chain = @backingInt(wip.root_list.items[2]);
        return .{
            .eb = try wip.toOwnedBundle("@as(comptime_int, 3)\n"),
            .root = root,
            .err_loc = @backingInt(err_loc),
            .chain = chain,
            .nested = @backingInt(nested),
        };
    }

    fn deinit(f: *Fixture) void {
        f.eb.deinit(testing.allocator);
    }
};

/// Reads all contents the way the standard library's read functions and
/// `diagnostics/compiler.zig` do: panics when out of bounds
fn readAll(eb: ErrorBundle) void {
    if (eb.extra.len == 0) return;
    std.mem.doNotOptimizeAway(eb.getCompileLogOutput().len);
    for (eb.getMessages()) |mi| readMessage(eb, mi);
}

fn readMessage(eb: ErrorBundle, mi: ErrorBundle.MessageIndex) void {
    const msg = eb.getErrorMessage(mi);
    std.mem.doNotOptimizeAway(eb.nullTerminatedString(msg.msg).len);
    if (msg.src_loc != .none) readLocation(eb, msg.src_loc);
    for (eb.getNotes(mi)) |note| readMessage(eb, note);
}

fn readLocation(eb: ErrorBundle, index: ErrorBundle.SourceLocationIndex) void {
    const loc = eb.getSourceLocation(index);
    std.mem.doNotOptimizeAway(eb.nullTerminatedString(loc.src_path).len);
    if (loc.source_line != 0) std.mem.doNotOptimizeAway(eb.nullTerminatedString(loc.source_line).len);
    const first = @backingInt(index) + location_words;
    for (0..loc.reference_trace_len) |k| {
        const decl_name = eb.extra[first + k * trace_words];
        const ref_loc: ErrorBundle.SourceLocationIndex = @fromBackingInt(eb.extra[first + k * trace_words + 1]);
        if (ref_loc != .none) {
            std.mem.doNotOptimizeAway(eb.nullTerminatedString(decl_name).len);
            readLocation(eb, ref_loc);
        } else if (decl_name != 0) {
            std.mem.doNotOptimizeAway(decl_name + loc.reference_trace_len - 1);
        }
    }
}

test "valid error bundle: notes, source lines, reference traces and compile log" {
    var f: Fixture = try .init();
    defer f.deinit();
    try testing.expect(isValid(f.eb));
    try testing.expect(isValid(.empty));
    readAll(f.eb);
    // The fixture follows the standard library's conventions: the standard library can render it
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try f.eb.renderToWriter(.{}, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "100000 reference(s) hidden; use '-freference-trace=100001'") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "note: and here") != null);
}

test "malformed error bundles are rejected" {
    const gpa = testing.allocator;
    var f: Fixture = try .init();
    defer f.deinit();
    const eb = f.eb;
    const extra_len: u32 = @intCast(eb.extra.len);
    const strings_len: u32 = @intCast(eb.string_bytes.len);
    const list_start = eb.getErrorMessageList().start;
    const trace = f.err_loc + location_words;
    const Case = struct { name: []const u8, at: u32, value: u32 };
    const cases = [_]Case{
        .{ .name = "message string out of range", .at = f.root, .value = strings_len },
        .{ .name = "list length past the end", .at = 0, .value = extra_len },
        .{ .name = "list start past the end", .at = 1, .value = extra_len - 1 },
        .{ .name = "compile log out of range", .at = 2, .value = strings_len },
        .{ .name = "message index out of range", .at = list_start, .value = extra_len - 2 },
        .{ .name = "src_loc out of range", .at = f.root + 2, .value = extra_len - 4 },
        .{ .name = "notes_len out of range", .at = f.root + 3, .value = extra_len },
        .{ .name = "note index out of range", .at = f.root + message_words, .value = std.math.maxInt(u32) },
        .{ .name = "src_path out of range", .at = f.err_loc, .value = std.math.maxInt(u32) },
        .{ .name = "source_line out of range", .at = f.err_loc + 6, .value = strings_len + 1 },
        .{ .name = "reference_trace_len out of range", .at = f.err_loc + 7, .value = extra_len },
        .{ .name = "reference name out of range", .at = trace, .value = strings_len },
        .{ .name = "reference location out of range", .at = trace + 1, .value = extra_len },
        .{ .name = "hidden reference count overflows", .at = trace + trace_words, .value = std.math.maxInt(u32) - 1 },
        .{ .name = "note refers to its own message", .at = f.root + message_words, .value = f.root },
        .{ .name = "note refers to an ancestor", .at = f.nested + message_words, .value = f.chain },
        .{ .name = "reference location refers to itself", .at = trace + 1, .value = f.err_loc },
    };
    for (cases) |c| {
        const extra = try gpa.dupe(u32, eb.extra);
        defer gpa.free(extra);
        extra[c.at] = c.value;
        const bad: ErrorBundle = .{ .string_bytes = eb.string_bytes, .extra = extra };
        if (isValid(bad)) {
            std.debug.print("accepted: {s}\n", .{c.name});
            return error.TestUnexpectedResult;
        }
    }

    // The last string (compile log) has no terminator
    const strings = try gpa.dupe(u8, eb.string_bytes);
    defer gpa.free(strings);
    strings[strings.len - 1] = 'x';
    try testing.expect(!isValid(.{ .string_bytes = strings, .extra = eb.extra }));
    // No strings; incomplete message list
    try testing.expect(!isValid(.{ .string_bytes = &.{}, .extra = eb.extra }));
    try testing.expect(!isValid(.{ .string_bytes = eb.string_bytes, .extra = eb.extra[0..2] }));
}

test "nested and shared references are bounded" {
    const gpa = testing.allocator;
    // Both notes of each message point to the message of the previous level: when expanded level
    // by level, the amount read is 2^levels
    for ([_]u32{ 2, 30 }, [_]bool{ true, false }) |levels, expected| {
        var extra: std.ArrayList(u32) = .empty;
        defer extra.deinit(gpa);
        try extra.appendSlice(gpa, &.{ 1, 0, 0 });
        var prev: u32 = 0;
        for (0..levels + 1) |level| {
            const index: u32 = @intCast(extra.items.len);
            try extra.appendSlice(gpa, &.{ 0, 1, 0, @as(u32, if (level == 0) 0 else 2) });
            if (level != 0) try extra.appendSlice(gpa, &.{ prev, prev });
            prev = index;
        }
        extra.items[1] = @intCast(extra.items.len);
        try extra.append(gpa, prev);
        const eb: ErrorBundle = .{ .string_bytes = "\x00", .extra = extra.items };
        try testing.expectEqual(expected, isValid(eb));
        if (expected) readAll(eb);
    }
}

test "every accepted mutation of a valid error bundle can be read" {
    const gpa = testing.allocator;
    var f: Fixture = try .init();
    defer f.deinit();
    const eb = f.eb;
    const extra = try gpa.dupe(u32, eb.extra);
    defer gpa.free(extra);
    const strings = try gpa.dupe(u8, eb.string_bytes);
    defer gpa.free(strings);
    const extra_len: u32 = @intCast(extra.len);
    const strings_len: u32 = @intCast(strings.len);
    for (extra, 0..) |original, i| {
        const values = [_]u32{ 0, 1, 2, 3, @intCast(i), extra_len - 1, extra_len, extra_len + 1, strings_len - 1, strings_len, std.math.maxInt(u32) - 1, std.math.maxInt(u32) };
        for (values) |value| {
            extra[i] = value;
            const mutated: ErrorBundle = .{ .string_bytes = strings, .extra = extra };
            if (isValid(mutated)) readAll(mutated);
        }
        extra[i] = original;
    }
    for (strings, 0..) |original, i| {
        strings[i] = if (original == 0) 'x' else 0;
        const mutated: ErrorBundle = .{ .string_bytes = strings, .extra = extra };
        if (isValid(mutated)) readAll(mutated);
        strings[i] = original;
    }
    for (0..extra.len) |n| {
        const truncated: ErrorBundle = .{ .string_bytes = strings, .extra = extra[0..n] };
        if (isValid(truncated)) readAll(truncated);
    }
    for (0..strings.len) |n| {
        const truncated: ErrorBundle = .{ .string_bytes = strings[0..n], .extra = extra };
        if (isValid(truncated)) readAll(truncated);
    }
}
