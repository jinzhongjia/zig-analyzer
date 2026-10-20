//! 每个文档只保留最新的完整语义令牌，按总容量与最近使用顺序淘汰。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const Cache = @This();

pub const Result = std.meta.Child(types.ResultType("textDocument/semanticTokens/full/delta"));
pub const max_documents = 128;
pub const max_bytes = 16 * 1024 * 1024;
/// 每个 token 占的整数个数
const token_len = 5;

mutex: Io.Mutex = .init,
entries: std.AutoArrayHashMapUnmanaged(FileId, Snapshot) = .empty,
bytes: usize = 0,
sequence: u128 = 0,

const Snapshot = struct {
    id: u128,
    data: []const u32,
};

pub fn deinit(cache: *Cache, gpa: Allocator) void {
    for (cache.entries.values()) |entry| gpa.free(entry.data);
    cache.entries.deinit(gpa);
    cache.* = .{};
}

pub fn remove(cache: *Cache, io: Io, gpa: Allocator, file: FileId) void {
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);
    if (cache.entries.getIndex(file)) |index| cache.removeAt(gpa, index);
}

fn removeAt(cache: *Cache, gpa: Allocator, index: usize) void {
    const entry = cache.entries.values()[index];
    cache.bytes -= entry.data.len * @sizeOf(u32);
    gpa.free(entry.data);
    cache.entries.swapRemoveAt(index);
}

/// 返回值只引用本次请求的内存；比较与替换在同一把锁内完成，不向读者借出缓存切片。
pub fn update(cache: *Cache, io: Io, gpa: Allocator, arena: Allocator, file: FileId, data: []const u32, previous_id: ?[]const u8) Allocator.Error!Result {
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);

    const next = cache.sequence + 1;
    const result_id = try std.fmt.allocPrint(arena, "{d}", .{next});
    var result: Result = .{ .SemanticTokens = .{ .resultId = result_id, .data = data } };
    const old = cache.entries.get(file);
    var unchanged: ?bool = null;
    if (old) |snapshot| if (previous_id) |previous| {
        var id_buf: [40]u8 = undefined;
        const cached_id = std.fmt.bufPrint(&id_buf, "{d}", .{snapshot.id}) catch unreachable;
        if (std.mem.eql(u8, previous, cached_id)) {
            // 前后缀按整个 token 比较：客户端把 edits 套用到不一致的基线上时（Neovim 0.12 的请求竞态），
            // 结果仍由完整的 token 组成，不会出现无法解码的残缺 token。
            const shared = @min(snapshot.data.len, data.len);
            var prefix: usize = 0;
            while (prefix + token_len <= shared and
                std.mem.eql(u32, snapshot.data[prefix..][0..token_len], data[prefix..][0..token_len])) : (prefix += token_len)
            {}
            var suffix: usize = 0;
            while (prefix + suffix + token_len <= shared and std.mem.eql(
                u32,
                snapshot.data[snapshot.data.len - suffix - token_len ..][0..token_len],
                data[data.len - suffix - token_len ..][0..token_len],
            )) : (suffix += token_len) {}
            const removed = snapshot.data.len - prefix - suffix;
            const inserted = data[prefix .. data.len - suffix];
            unchanged = removed == 0 and inserted.len == 0;
            var edits: []const types.SemanticTokensEdit = &.{};
            if (removed != 0 or inserted.len != 0) {
                const edit = try arena.alloc(types.SemanticTokensEdit, 1);
                edit[0] = .{ .start = @intCast(prefix), .deleteCount = @intCast(removed), .data = if (inserted.len == 0) null else inserted };
                edits = edit;
            }
            result = .{ .SemanticTokensDelta = .{ .resultId = result_id, .edits = edits } };
        }
    };
    if (old) |snapshot| if (unchanged orelse std.mem.eql(u32, snapshot.data, data)) {
        cache.entries.getPtr(file).?.id = next;
        cache.sequence = next;
        return result;
    };

    const size = data.len * @sizeOf(u32);
    if (size <= max_bytes) {
        // 分配失败时保留旧快照与旧 ID；没有中途淘汰成功请求可用的基线。
        const owned = try gpa.dupe(u32, data);
        errdefer gpa.free(owned);
        if (old == null and cache.entries.count() < max_documents and cache.bytes + size <= max_bytes) {
            try cache.entries.ensureUnusedCapacity(gpa, 1);
        }
        if (cache.entries.getIndex(file)) |index| cache.removeAt(gpa, index);
        while (cache.entries.count() >= max_documents or cache.bytes + size > max_bytes) {
            var oldest: usize = 0;
            for (cache.entries.values(), 0..) |entry, index| {
                if (entry.id < cache.entries.values()[oldest].id) oldest = index;
            }
            cache.removeAt(gpa, oldest);
        }
        cache.entries.putAssumeCapacity(file, .{ .id = next, .data = owned });
        cache.bytes += size;
    } else if (cache.entries.getIndex(file)) |index| {
        // 超大文档仍可返回完整结果，但不复制并长期保留它。
        cache.removeAt(gpa, index);
    }
    cache.sequence = next;
    return result;
}

test "semantic cache edits whole tokens including insertion and deletion" {
    const testing = std.testing;
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file: FileId = @fromBackingInt(@intCast(1));
    const first = (try cache.update(testing.io, testing.allocator, arena, file, &.{ 0, 0, 3, 1, 0, 1, 0, 5, 2, 0 }, null)).SemanticTokens;
    // 只差长度或修饰符这一个整数时也替换整个 token
    const changed = (try cache.update(testing.io, testing.allocator, arena, file, &.{ 0, 0, 4, 1, 0, 1, 0, 5, 2, 0 }, first.resultId)).SemanticTokensDelta;
    try testing.expectEqual(1, changed.edits.len);
    try testing.expectEqual(0, changed.edits[0].start);
    try testing.expectEqual(5, changed.edits[0].deleteCount);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 4, 1, 0 }, changed.edits[0].data.?);
    const modified = (try cache.update(testing.io, testing.allocator, arena, file, &.{ 0, 0, 4, 1, 0, 1, 0, 5, 2, 1 }, changed.resultId)).SemanticTokensDelta;
    try testing.expectEqual(5, modified.edits[0].start);
    try testing.expectEqual(5, modified.edits[0].deleteCount);
    try testing.expectEqualSlices(u32, &.{ 1, 0, 5, 2, 1 }, modified.edits[0].data.?);
    const deleted = (try cache.update(testing.io, testing.allocator, arena, file, &.{}, modified.resultId)).SemanticTokensDelta;
    try testing.expectEqual(0, deleted.edits[0].start);
    try testing.expectEqual(10, deleted.edits[0].deleteCount);
    try testing.expect(deleted.edits[0].data == null);
    const inserted = (try cache.update(testing.io, testing.allocator, arena, file, &.{ 0, 0, 1, 0, 0 }, deleted.resultId)).SemanticTokensDelta;
    try testing.expectEqual(0, inserted.edits[0].deleteCount);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 0, 0 }, inserted.edits[0].data.?);
}

test "semantic cache bounds document snapshots and drops closed baselines" {
    const testing = std.testing;
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = (try cache.update(testing.io, testing.allocator, arena, @fromBackingInt(@intCast(0)), &.{ 0, 0, 1, 0, 0 }, null)).SemanticTokens;
    for (1..max_documents + 1) |index| {
        _ = try cache.update(testing.io, testing.allocator, arena, @fromBackingInt(@intCast(index)), &.{ 0, 0, 1, 0, 0 }, null);
    }
    try testing.expectEqual(max_documents, cache.entries.count());
    const evicted = try cache.update(testing.io, testing.allocator, arena, @fromBackingInt(@intCast(0)), &.{ 0, 0, 1, 0, 0 }, first.resultId);
    try testing.expect(evicted == .SemanticTokens);
    cache.remove(testing.io, testing.allocator, @fromBackingInt(@intCast(0)));
    const closed = try cache.update(testing.io, testing.allocator, arena, @fromBackingInt(@intCast(0)), &.{ 0, 0, 1, 0, 0 }, evicted.SemanticTokens.resultId);
    try testing.expect(closed == .SemanticTokens);
}

test "semantic cache does not retain oversized token arrays" {
    const testing = std.testing;
    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try testing.allocator.alloc(u32, max_bytes / @sizeOf(u32) + 1);
    defer testing.allocator.free(data);
    @memset(data, 0);
    const first = (try cache.update(testing.io, testing.allocator, arena, @fromBackingInt(@intCast(0)), data, null)).SemanticTokens;
    const next = try cache.update(testing.io, testing.allocator, arena, @fromBackingInt(@intCast(0)), data, first.resultId);
    try testing.expect(next == .SemanticTokens);
    try testing.expectEqual(0, cache.entries.count());
    try testing.expectEqual(0, cache.bytes);
}

test "semantic cache allocation failures preserve the previous baseline" {
    const testing = std.testing;
    var fail_offset: usize = 0;
    while (true) : (fail_offset += 1) {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = failing.allocator();
        var cache: Cache = .{};
        defer cache.deinit(gpa);
        var baseline_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer baseline_arena.deinit();
        const first = (try cache.update(testing.io, gpa, baseline_arena.allocator(), @fromBackingInt(@intCast(0)), &.{ 0, 0, 1, 0, 0 }, null)).SemanticTokens;
        var request_arena: std.heap.ArenaAllocator = .init(gpa);
        defer request_arena.deinit();
        failing.fail_index = failing.alloc_index + fail_offset;
        const attempt = cache.update(testing.io, gpa, request_arena.allocator(), @fromBackingInt(@intCast(0)), &.{ 0, 0, 2, 0, 0 }, first.resultId) catch |err| blk: {
            try testing.expectEqual(error.OutOfMemory, err);
            break :blk null;
        };
        const failed = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        const previous = if (attempt) |result| result.SemanticTokensDelta.resultId else first.resultId;
        const recovered = (try cache.update(testing.io, gpa, baseline_arena.allocator(), @fromBackingInt(@intCast(0)), &.{ 0, 0, 2, 0, 0 }, previous)).SemanticTokensDelta;
        try testing.expectEqual(@as(usize, if (failed) 1 else 0), recovered.edits.len);
        if (!failed) break;
    }
}

test "semantic cache byte eviction preserves recently refreshed snapshots and failed inserts" {
    const testing = std.testing;
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 两个文档放得下、三个放不下；数据由完整的 token 组成
    const data = try testing.allocator.alloc(u32, max_bytes / @sizeOf(u32) / 2 / token_len * token_len);
    defer testing.allocator.free(data);
    @memset(data, 0);
    const first_file: FileId = @fromBackingInt(@intCast(1));
    const second_file: FileId = @fromBackingInt(@intCast(2));
    const third_file: FileId = @fromBackingInt(@intCast(3));
    const first = (try cache.update(testing.io, gpa, arena, first_file, data, null)).SemanticTokens;
    const second = (try cache.update(testing.io, gpa, arena, second_file, data, null)).SemanticTokens;
    const touched = (try cache.update(testing.io, gpa, arena, first_file, data, first.resultId)).SemanticTokensDelta;
    try testing.expectEqual(0, touched.edits.len);
    try testing.expectEqual(2 * data.len * @sizeOf(u32), cache.bytes);
    const sequence = cache.sequence;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, cache.update(testing.io, gpa, arena, third_file, data, null));
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(sequence, cache.sequence);
    try testing.expectEqual(2 * data.len * @sizeOf(u32), cache.bytes);
    try testing.expectEqual(2, cache.entries.count());
    try testing.expect(cache.entries.contains(first_file));
    try testing.expect(cache.entries.contains(second_file));
    try testing.expect(!cache.entries.contains(third_file));
    _ = try cache.update(testing.io, gpa, arena, third_file, data, null);
    try testing.expectEqual(2 * data.len * @sizeOf(u32), cache.bytes);
    try testing.expectEqual(2, cache.entries.count());
    try testing.expect(cache.entries.contains(first_file));
    try testing.expect(!cache.entries.contains(second_file));
    const retained = (try cache.update(testing.io, gpa, arena, first_file, data, touched.resultId)).SemanticTokensDelta;
    try testing.expectEqual(0, retained.edits.len);
    const evicted = try cache.update(testing.io, gpa, arena, second_file, data, second.resultId);
    try testing.expect(evicted == .SemanticTokens);
    try testing.expectEqual(2 * data.len * @sizeOf(u32), cache.bytes);
}

test "semantic cache initial allocation failures leave no partial baseline" {
    const testing = std.testing;
    var fail_offset: usize = 0;
    while (true) : (fail_offset += 1) {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_offset });
        const gpa = failing.allocator();
        var cache: Cache = .{};
        defer cache.deinit(gpa);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const file: FileId = @fromBackingInt(@intCast(0));
        const attempt = cache.update(testing.io, gpa, arena_state.allocator(), file, &.{ 0, 0, 1, 0, 0 }, null) catch |err| blk: {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(0, cache.entries.count());
            try testing.expectEqual(0, cache.bytes);
            try testing.expectEqual(0, cache.sequence);
            break :blk null;
        };
        failing.fail_index = std.math.maxInt(usize);
        if (attempt != null) break;
        const recovered = try cache.update(testing.io, gpa, arena_state.allocator(), file, &.{ 0, 0, 1, 0, 0 }, "1");
        try testing.expect(recovered == .SemanticTokens);
        try testing.expectEqualStrings("1", recovered.SemanticTokens.resultId.?);
        try testing.expectEqual(1, cache.entries.count());
        try testing.expectEqual(5 * @sizeOf(u32), cache.bytes);
    }
}

test "semantic cache document eviction waits for successful allocation" {
    const testing = std.testing;
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var first_id: ?[]const u8 = null;
    for (0..max_documents) |index| {
        const result = (try cache.update(testing.io, gpa, arena, @fromBackingInt(@intCast(index)), &.{ 0, 0, 1, 0, 0 }, null)).SemanticTokens;
        if (index == 0) first_id = result.resultId;
    }
    const sequence = cache.sequence;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, cache.update(testing.io, gpa, arena, @fromBackingInt(@intCast(max_documents)), &.{ 0, 0, 1, 0, 0 }, null));
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(sequence, cache.sequence);
    try testing.expectEqual(max_documents, cache.entries.count());
    try testing.expectEqual(max_documents * 5 * @sizeOf(u32), cache.bytes);
    const retained = (try cache.update(testing.io, gpa, arena, @fromBackingInt(@intCast(0)), &.{ 0, 0, 1, 0, 0 }, first_id)).SemanticTokensDelta;
    try testing.expectEqual(0, retained.edits.len);
    _ = try cache.update(testing.io, gpa, arena, @fromBackingInt(@intCast(max_documents)), &.{ 0, 0, 1, 0, 0 }, null);
    try testing.expectEqual(max_documents, cache.entries.count());
    try testing.expect(cache.entries.contains(@fromBackingInt(@intCast(0))));
    try testing.expect(!cache.entries.contains(@fromBackingInt(@intCast(1))));
}
