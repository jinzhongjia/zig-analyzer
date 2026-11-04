const std = @import("std");
const testing = std.testing;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const FileText = @import("../base/inputs.zig").FileText;
const q = @import("queries.zig");

/// Downstream query depending on ItemTree: counts the members
const ItemCount = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = usize;
    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        return (try ctx.get(q.FileItemTree, file)).items.len;
    }
};

const SemanticCount = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = usize;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        return (try ctx.get(q.ItemNames, file)).len + (try ctx.get(q.ContainerRels, file)).len;
    }
};

const Db = engine.Engine(void, &.{ FileText, q.SyntaxDialect, q.SourceText, q.ParseFile, q.FileItemTree, q.FileAstIdMap, q.ItemSummaries, q.ItemNames, q.ContainerRels, ItemCount, SemanticCount });

fn setText(db: *Db, file: Vfs.FileId, text: []const u8) !void {
    db.beginWrite();
    defer db.endWrite();
    try db.set(FileText, file, try testing.allocator.dupe(u8, text), .low);
}

fn count(db: *Db, file: Vfs.FileId) !usize {
    var ctx = db.beginRead(testing.allocator);
    defer ctx.end();
    return ctx.get(ItemCount, file);
}

fn executions(db: *Db, comptime Q: type) u64 {
    return db.executions(Q);
}

test "ItemSummary mentions long escaped names" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));
    const suffix: [300]u8 = @splat('b');
    // 301 bytes after decoding, more than the 256-byte buffer of the old implementation
    const source = try std.fmt.allocPrint(testing.allocator, "fn f() void {{\n    const x = @\"\\x41{s}\";\n}}\n", .{suffix});
    defer testing.allocator.free(source);
    const name = try std.fmt.allocPrint(testing.allocator, "A{s}", .{suffix});
    defer testing.allocator.free(name);
    try setText(&db, file, source);
    var ctx = db.beginRead(testing.allocator);
    defer ctx.end();
    const summaries = try ctx.get(q.ItemSummaries, file);
    try testing.expectEqual(1, summaries.items.len);
    try testing.expect(summaries.items[0].mayMention(name));
}

test "ParseFile bytes include the incremental chain" {
    const Parse = @import("Parse.zig");
    const base = "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// end\n";
    const old = try Parse.create(testing.allocator, base, .zig);
    defer old.destroy();
    // An edit at the end takes the top-level local reparse path: the new result holds the old one
    const inc = try Parse.reparse(testing.allocator, old, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// endx\n");
    defer inc.destroy();
    try testing.expect(inc.base != null);
    try testing.expect(inc.chain_bytes > inc.arena.queryCapacity());
    try testing.expectEqual(@sizeOf(Parse) + inc.chain_bytes, q.ParseFile.bytes(inc));
}

test "changing the dialect parses files again by its rules" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));
    try setText(&db, file, "extern fn f(\n    /// doc\n    ...,\n) void;\n");
    for ([_]struct { @import("Parse.zig").Dialect, usize }{ .{ .latest, 1 }, .{ .zig_0_17_0, 0 }, .{ .zig_0_17_1, 1 } }) |case| {
        const dialect, const errors = case;
        {
            db.beginWrite();
            defer db.endWrite();
            try db.set(q.SyntaxDialect, {}, dialect, .high);
        }
        var ctx = db.beginRead(testing.allocator);
        defer ctx.end();
        const parse = try ctx.get(q.ParseFile, file);
        try testing.expectEqual(dialect, parse.dialect);
        try testing.expectEqual(errors, parse.errors.len);
    }
}

test "FileAstIdMap bytes include the retained parse" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));
    try setText(&db, file, "const a = 1;\nfn f() void { _ = a; }\n");
    var ctx = db.beginRead(testing.allocator);
    defer ctx.end();
    _ = try ctx.get(q.ParseFile, file);
    const map = try ctx.get(q.FileAstIdMap, file);
    try testing.expect(q.FileAstIdMap.bytes(map) > map.bytes());
}

test "body-only edit: reparse and rebuild ItemTree, downstream not recomputed" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));

    try setText(&db, file, "const a = 1;\nfn f() void { _ = a; }\n");
    try testing.expectEqual(2, try count(&db, file));

    try setText(&db, file, "const a = 1;\nfn f() void {\n    _ = a + 1;\n}\n");
    try testing.expectEqual(2, try count(&db, file));
    try testing.expectEqual(2, executions(&db, q.ParseFile));
    try testing.expectEqual(2, executions(&db, q.FileItemTree));
    try testing.expectEqual(1, executions(&db, ItemCount));

    // New declaration: ItemTree changes, downstream is recomputed
    try setText(&db, file, "const a = 1;\nconst b = 2;\nfn f() void {}\n");
    try testing.expectEqual(3, try count(&db, file));
    try testing.expectEqual(2, executions(&db, ItemCount));
}

test "AstIdMap points to the latest tree" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));
    try setText(&db, file, "fn f() void {}");
    try setText(&db, file, "\n\nfn f() void {}");

    var ctx = db.beginRead(testing.allocator);
    defer ctx.end();
    const items = try ctx.get(q.FileItemTree, file);
    const map = try ctx.get(q.FileAstIdMap, file);
    const node = map.get(items.items[0].ast_id).?;
    try testing.expectEqual(2, node.range().start);
}

test "ParseFile uses block reparse after edits inside a function body" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@intCast(0));
    try setText(&db, file, "fn f() void {\n    a();\n}\n");
    {
        var ctx = db.beginRead(testing.allocator);
        defer ctx.end();
        try testing.expectEqual(null, (try ctx.get(q.ParseFile, file)).base);
    }
    try setText(&db, file, "fn f() void {\n    b();\n}\n");
    try setText(&db, file, "fn f() void {\n    b(1);\n}\n");
    var ctx = db.beginRead(testing.allocator);
    defer ctx.end();
    const parse = try ctx.get(q.ParseFile, file);
    try testing.expect(parse.base != null);
    const full = try @import("Parse.zig").create(testing.allocator, "fn f() void {\n    b(1);\n}\n", .zig);
    defer full.destroy();
    try testing.expect(parse.sameAs(full));
}

test "semantic name and container summaries ignore prefix locations but retain semantic changes" {
    var db: Db = .init(testing.io, testing.allocator, {});
    defer db.deinit();
    const file: Vfs.FileId = @fromBackingInt(@as(u32, 0));
    const text = "fn f() void { const Local = struct { value: u8 }; _ = Local; }\n";
    const get = struct {
        fn semantic(db_: *Db, file_: Vfs.FileId) !usize {
            var ctx = db_.beginRead(testing.allocator);
            defer ctx.end();
            return ctx.get(SemanticCount, file_);
        }
    }.semantic;
    try setText(&db, file, text);
    _ = try get(&db, file);
    const before = db.executions(SemanticCount);
    try setText(&db, file, "// prefix\n" ++ text);
    _ = try get(&db, file);
    try testing.expectEqual(before, db.executions(SemanticCount));
    try setText(&db, file, text);
    _ = try get(&db, file);
    try testing.expectEqual(before, db.executions(SemanticCount));
    try setText(&db, file, "fn f() void { const Local = struct { other: u8 }; _ = Local; }\n");
    _ = try get(&db, file);
    try testing.expectEqual(before + 1, db.executions(SemanticCount));
    try setText(&db, file, "fn f() void { const Local =  struct { other: u8 }; _ = Local; }\n");
    _ = try get(&db, file);
    try testing.expectEqual(before + 2, db.executions(SemanticCount));
}
