//! Lifetimes of the file text buffer shared by `FileText` and parse results: a chain of incremental
//! reparses whose reused green tokens point into the buffer of the full parse at its base, readers
//! that race with the replacement of the input, and the ownership of a buffer given to the engine.
//! All use `std.testing.allocator`, so a leak or a double release fails the test.

const std = @import("std");
const testing = std.testing;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const inputs = @import("../base/inputs.zig");
const q = @import("queries.zig");
const Parse = @import("Parse.zig");
const Text = inputs.Text;
const SyntaxNode = @import("tree.zig").SyntaxNode;

const Db = engine.Engine(void, &.{ inputs.FileText, q.SyntaxDialect, q.SourceText, q.ParseFile });

fn setText(db: *Db, file: Vfs.FileId, text: []const u8) !void {
    const owned = try Text.init(testing.allocator, text);
    db.beginWrite();
    defer db.endWrite();
    try db.set(inputs.FileText, file, owned, .low);
}

/// Total number of bytes covered by the tokens of a parse, and a checksum of their text, which
/// reads through every token slice (they point into arenas and buffers along the chain)
fn tokenStats(root: SyntaxNode) struct { len: usize, hash: u64 } {
    var acc = struct {
        len: usize = 0,
        h: std.hash.Wyhash = std.hash.Wyhash.init(0),

        fn walk(self: *@This(), n: SyntaxNode) void {
            var it = n.children();
            while (it.next()) |e| switch (e) {
                .token => |t| {
                    self.len += t.text.len;
                    self.h.update(t.text);
                },
                .node => |c| self.walk(c),
            };
        }
    }{};
    acc.walk(root);
    return .{ .len = acc.len, .hash = acc.h.final() };
}

/// Replaces the body between `fn edit() void {` and the following `}`
fn editBody(gpa: std.mem.Allocator, text: []const u8, body: []const u8) ![]u8 {
    const open = std.mem.indexOf(u8, text, "fn edit() void {").?;
    const start = open + "fn edit() void {".len;
    const end = start + std.mem.indexOf(u8, text[start..], "}").?;
    return std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ text[0..start], body, text[end..] });
}

fn makeBase(gpa: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.print(gpa, "fn edit() void {{ g(); }}\n", .{});
    for (0..150) |i| try buf.print(gpa, "const a{d} = {d};\nfn f{d}() void {{ h({d}); }}\n", .{ i, i, i, i });
    return buf.toOwnedSlice(gpa);
}

test "shared text: a chain from a shared full parse keeps every reused token alive" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));

    var current = try makeBase(testing.allocator);
    defer testing.allocator.free(current);
    var kept: ?*Parse = null;

    const versions = 80;
    for (0..versions) |v| {
        const body = try std.fmt.allocPrint(testing.allocator, "g({d}, {d});", .{ v, v });
        defer testing.allocator.free(body);
        const next = try editBody(testing.allocator, current, body);
        testing.allocator.free(current);
        current = next;
        try setText(&db, file, current);

        var parse: *Parse = undefined;
        {
            var ctx = db.beginRead(testing.allocator);
            defer ctx.end();
            const ft = (try ctx.get(inputs.FileText, file)).?;
            try testing.expectEqualStrings(current, ft.bytes());
            parse = try ctx.get(q.ParseFile, file);
            // The result shares the buffer of the input of this revision
            try testing.expectEqual(ft.source().ptr, parse.source.ptr);
            try testing.expectEqualStrings(current, parse.source);
        }
        // Every result matches a full parse of the same text, so every reused token still reads
        // the bytes it was parsed from (the full parse at the base retains its buffer)
        {
            const full = try Parse.create(testing.allocator, current, .zig);
            defer full.destroy();
            try testing.expect(parse.sameAs(full));
            const a = tokenStats(parse.rootNode());
            const b = tokenStats(full.rootNode());
            try testing.expectEqual(b.len, a.len);
            try testing.expectEqual(b.hash, a.hash);
        }
        if (kept) |k| k.destroy();
        kept = parse.retain();
    }

    // Replace the input once more: the retained parse still reads its own revision
    try setText(&db, file, "const z = 1;\n");
    {
        const full = try Parse.create(testing.allocator, current, .zig);
        defer full.destroy();
        try testing.expect(kept.?.sameAs(full));
        try testing.expectEqualStrings(current, kept.?.source);
    }
    kept.?.destroy();
}

test "shared text: edits and concurrent reads race with the replacement of the input" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));

    const base = try makeBase(testing.allocator);
    defer testing.allocator.free(base);
    try setText(&db, file, base);

    const Reader = struct {
        db: *Db,
        stop: *std.atomic.Value(bool),
        failures: *std.atomic.Value(usize),

        fn run(r: *const @This()) void {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            while (!r.stop.load(.acquire)) {
                defer _ = arena_state.reset(.retain_capacity);
                var ctx = r.db.beginRead(arena_state.allocator());
                const ft = ctx.get(inputs.FileText, file) catch |err| switch (err) {
                    error.Canceled => {
                        ctx.end();
                        continue;
                    },
                    error.OutOfMemory => {
                        ctx.end();
                        _ = r.failures.fetchAdd(1, .monotonic);
                        return;
                    },
                } orelse {
                    ctx.end();
                    _ = r.failures.fetchAdd(1, .monotonic);
                    return;
                };
                const parse = ctx.get(q.ParseFile, file) catch |err| switch (err) {
                    error.Canceled => {
                        ctx.end();
                        continue;
                    },
                    error.OutOfMemory => {
                        ctx.end();
                        _ = r.failures.fetchAdd(1, .monotonic);
                        return;
                    },
                };
                if (!std.mem.eql(u8, parse.source, ft.bytes())) _ = r.failures.fetchAdd(1, .monotonic);
                if (parse.source.len == 0) _ = r.failures.fetchAdd(1, .monotonic);
                // Read through the green tokens of the (possibly incremental) tree
                const stats = tokenStats(parse.rootNode());
                if (stats.len != parse.source.len) _ = r.failures.fetchAdd(1, .monotonic);
                ctx.end();
            }
        }
    };

    var stop = std.atomic.Value(bool).init(false);
    var failures = std.atomic.Value(usize).init(0);
    const reader = Reader{ .db = &db, .stop = &stop, .failures = &failures };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{ .stack_size = 8 << 20 }, Reader.run, .{&reader});

    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const body = try std.fmt.allocPrint(testing.allocator, "g({d}, {d});", .{ i, i });
        defer testing.allocator.free(body);
        const text = try editBody(testing.allocator, base, body);
        defer testing.allocator.free(text);
        try setText(&db, file, text);
        // Some reads force a full parse instead of a local reparse
        if (i % 17 == 0) {
            var ctx = db.beginRead(testing.allocator);
            defer ctx.end();
            _ = ctx.get(q.ParseFile, file) catch |err| switch (err) {
                error.Canceled => continue,
                error.OutOfMemory => return err,
            };
        }
    }
    stop.store(true, .release);
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 0), failures.load(.acquire));
}

test "shared text: a parse retains the buffer after the caller releases it" {
    const a = testing.allocator;
    const text = "const a = 1;\nfn f() void { g(); }\n";
    const buffer: *Text = try .init(a, text);
    const full = try Parse.createInShared(a, buffer, .zig, .latest);
    const old = try Parse.create(a, text, .zig);
    defer old.destroy();
    // The parse holds its own reference: the caller can release its own at once
    buffer.release(a);
    defer full.destroy();
    try testing.expect(full.sameAs(old));
    try testing.expectEqualStrings(text, full.source);
    try testing.expectEqual(@as(u8, 0), full.source[text.len]);

    // A new buffer for the incremental result; the caller releases it at once too
    const new_text = "const a = 1;\nfn f() void { g(1); }\n";
    const new_buffer: *Text = try .init(a, new_text);
    const inc = try Parse.reparseShared(a, full, new_buffer);
    new_buffer.release(a);
    defer inc.destroy();
    try testing.expectEqualStrings(new_text, inc.source);
    // The base's buffer is still alive (the parse retains it)
    try testing.expectEqualStrings(text, full.source);
}

test "shared text: an incremental result keeps the base arena after the base is destroyed" {
    const a = testing.allocator;
    const text = "const a = 1;\nfn f() void {\n    g();\n}\nconst b = 2;\n";
    const v0: *Text = try .init(a, text);
    const p0 = try Parse.createInShared(a, v0, .zig, .latest);
    v0.release(a);
    const v1: *Text = try .init(a, "const a = 1;\nfn f() void {\n    g(1, 2);\n}\nconst b = 2;\n");
    const p1 = try Parse.reparseShared(a, p0, v1);
    v1.release(a);
    defer p1.destroy();
    // The engine drops the base (the result of the previous revision) while the result still
    // reuses its nodes: its arena and its buffer must stay alive
    p0.destroy();
    try testing.expect(p1.base != null);
    try testing.expectEqualStrings("const a = 1;\nfn f() void {\n    g(1, 2);\n}\nconst b = 2;\n", p1.source);
    const full = try Parse.create(a, p1.source, .zig);
    defer full.destroy();
    try testing.expect(p1.sameAs(full));
}

test "shared text: an equal input keeps the installed buffer" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(2));
    const text = "const a = 1;\nfn f() void { g(); }\n";
    try setText(&db, file, text);

    var first: *Text = undefined;
    var first_parse: *Parse = undefined;
    {
        var ctx = db.beginRead(testing.allocator);
        defer ctx.end();
        first = (try ctx.get(inputs.FileText, file)).?;
        first_parse = try ctx.get(q.ParseFile, file);
    }
    // Same bytes in a new buffer: the engine keeps the installed value and releases the new one
    try setText(&db, file, text);
    {
        var ctx = db.beginRead(testing.allocator);
        defer ctx.end();
        const now = (try ctx.get(inputs.FileText, file)).?;
        try testing.expectEqual(first, now);
        try testing.expectEqualStrings(text, now.bytes());
        const parse = try ctx.get(q.ParseFile, file);
        try testing.expectEqual(first_parse, parse);
        try testing.expectEqual(now.source().ptr, parse.source.ptr);
    }
}

test "shared text: evicted parses release their buffer" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(3));
    db.setLru(q.ParseFile, 1, 64 * 1024);
    const base = try makeBase(testing.allocator);
    defer testing.allocator.free(base);

    var current = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(current);
    for (0..40) |v| {
        const body = try std.fmt.allocPrint(testing.allocator, "g({d}, {d});", .{ v, v });
        defer testing.allocator.free(body);
        const next = try editBody(testing.allocator, current, body);
        testing.allocator.free(current);
        current = next;
        try setText(&db, file, current);
        {
            var ctx = db.beginRead(testing.allocator);
            defer ctx.end();
            _ = try ctx.get(q.ParseFile, file);
        }
        // The memo over the tiny capacity is evicted at the next sweep: the parse result is
        // destroyed and releases its buffer while the chain below it may still be alive
        db.setLru(q.ParseFile, 1, 1);
        while (!db.trySweep()) {}
    }
}

test "shared text: empty, tiny and repeatedly replaced parses share correctly" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(1));

    const cases = [_][]const u8{ "", "a", "a\n", "const x = 1;", "fn f() void {}\n" };
    for (cases) |text| {
        try setText(&db, file, text);
        var ctx = db.beginRead(testing.allocator);
        defer ctx.end();
        const ft = (try ctx.get(inputs.FileText, file)).?;
        const parse = try ctx.get(q.ParseFile, file);
        try testing.expectEqual(ft.source().ptr, parse.source.ptr);
        try testing.expectEqualStrings(text, parse.source);
        try testing.expectEqual(@as(u8, 0), parse.source[text.len]);
    }
}

test "shared text: a failed input set releases the text once" {
    // `db.set` takes ownership of the value whether or not it can store it, so the input's buffer
    // is released exactly once; a caller that released it again would free it twice.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var db: Db = .init(testing.io, failing.allocator(), {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));
    const text: *Text = try .init(failing.allocator(), "const a = 1;\n");
    db.beginWrite();
    defer db.endWrite();
    // The next allocation is the slot of the key, which was never interned
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, db.set(inputs.FileText, file, text, .low));
}
