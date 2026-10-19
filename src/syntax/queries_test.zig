const std = @import("std");
const testing = std.testing;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const FileText = @import("../base/inputs.zig").FileText;
const q = @import("queries.zig");

/// 依赖 ItemTree 的下游 query：统计成员数
const ItemCount = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = usize;
    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        return (try ctx.get(q.FileItemTree, file)).items.len;
    }
};

const Db = engine.Engine(void, &.{ FileText, q.SourceText, q.ParseFile, q.FileItemTree, q.FileAstIdMap, q.ItemSummaries, ItemCount });

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
    // 解码后 301 字节，超过旧实现的 256 字节缓冲
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

    // 新增声明：ItemTree 变化，下游重算
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
    const full = try @import("Parse.zig").create(testing.allocator, "fn f() void {\n    b(1);\n}\n");
    defer full.destroy();
    try testing.expect(parse.sameAs(full));
}
