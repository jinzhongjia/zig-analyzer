const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const Harness = @import("test_harness.zig").Harness;
const Cache = @import("semantic_cache.zig");

const document = types.TextDocumentIdentifier{ .uri = "untitled:semantic-tokens.zig" };
const other_document = types.TextDocumentIdentifier{ .uri = "untitled:semantic-tokens-other.zig" };

fn initialize(h: *Harness, encoding: []const u8, refresh: bool) !std.json.Value {
    return h.request("initialize", .{
        .capabilities = .{
            .general = .{ .positionEncodings = &[_][]const u8{encoding} },
            .workspace = .{ .semanticTokens = .{ .refreshSupport = refresh } },
        },
        .initializationOptions = .{ .diagnostics = .{ .debounce_ms = 0 } },
    });
}

fn open(h: *Harness, doc: types.TextDocumentIdentifier, text: []const u8) !void {
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = doc.uri, .languageId = "zig", .version = 1, .text = text } });
}

fn change(h: *Harness, doc: types.TextDocumentIdentifier, text: []const u8) !void {
    try h.notify("textDocument/didChange", .{
        .textDocument = .{ .uri = doc.uri, .version = 2 },
        .contentChanges = &.{.{ .text = text }},
    });
}

fn decode(comptime T: type, h: *Harness, message: std.json.Value) !T {
    try testing.expect(message.object.get("error") == null);
    return std.json.parseFromValueLeaky(T, h.arena.allocator(), message.object.get("result").?, .{ .ignore_unknown_fields = true });
}

fn full(h: *Harness, doc: types.TextDocumentIdentifier) !types.SemanticTokens {
    return decode(types.SemanticTokens, h, try h.request("textDocument/semanticTokens/full", .{ .textDocument = doc }));
}

fn delta(h: *Harness, doc: types.TextDocumentIdentifier, previous: []const u8) !Cache.Result {
    return decode(Cache.Result, h, try h.request("textDocument/semanticTokens/full/delta", .{ .textDocument = doc, .previousResultId = previous }));
}

fn replay(h: *Harness, old: []const u32, edits: []const types.SemanticTokensEdit) ![]const u32 {
    var output: std.ArrayList(u32) = .empty;
    var cursor: usize = 0;
    for (edits) |edit| {
        try testing.expect(edit.start >= cursor);
        try testing.expect(edit.start + edit.deleteCount <= old.len);
        try output.appendSlice(h.arena.allocator(), old[cursor..edit.start]);
        try output.appendSlice(h.arena.allocator(), edit.data orelse &.{});
        cursor = edit.start + edit.deleteCount;
    }
    try output.appendSlice(h.arena.allocator(), old[cursor..]);
    return output.items;
}

test "semantic token full and delta responses replay and unknown baselines fall back to full" {
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const init = try initialize(&h, "utf-16", false);
    const capability = init.object.get("result").?.object.get("capabilities").?.object.get("semanticTokensProvider").?.object;
    try testing.expect(capability.get("full").?.object.get("delta").?.bool);
    try testing.expect(capability.get("range").?.bool);

    const source = "const alpha = 1;\nconst text = \"hello\";\nfn use() void { _ = alpha; }\n";
    try open(&h, document, source);
    const first = try full(&h, document);
    try testing.expectEqual(0, first.data.len % 5);
    const unchanged = (try delta(&h, document, first.resultId.?)).SemanticTokensDelta;
    try testing.expectEqual(0, unchanged.edits.len);
    try testing.expect(!std.mem.eql(u8, first.resultId.?, unchanged.resultId.?));

    try change(&h, document, "const alpha = true;\nconst text = \"hello\";\nfn use() void { _ = alpha; }\n");
    const edited = (try delta(&h, document, unchanged.resultId.?)).SemanticTokensDelta;
    try testing.expectEqual(1, edited.edits.len);
    const actual = try replay(&h, first.data, edited.edits);
    const fresh = try full(&h, document);
    try testing.expectEqualSlices(u32, fresh.data, actual);
    const edit = edited.edits[0];
    try testing.expectEqual(0, edit.start % 5);
    try testing.expectEqual(0, edit.deleteCount % 5);
    if (edit.start > 0) try testing.expectEqualSlices(u32, first.data[0..edit.start], fresh.data[0..edit.start]);
    if (edit.data) |inserted| {
        try testing.expectEqual(0, inserted.len % 5);
        try testing.expect(!std.mem.eql(u32, first.data[edit.start..][0..5], inserted[0..5]));
        if (edit.start + edit.deleteCount < first.data.len) {
            try testing.expect(!std.mem.eql(u32, first.data[edit.start + edit.deleteCount - 5 ..][0..5], inserted[inserted.len - 5 ..][0..5]));
        }
    }
    const unknown = (try delta(&h, document, "unknown-result")).SemanticTokens;
    try testing.expectEqualSlices(u32, fresh.data, unknown.data);
    const stale = (try delta(&h, document, fresh.resultId.?)).SemanticTokens;
    try testing.expectEqualSlices(u32, fresh.data, stale.data);

    try open(&h, other_document, source);
    const other = try full(&h, other_document);
    try testing.expect(!std.mem.eql(u8, stale.resultId.?, other.resultId.?));
    const mismatched = (try delta(&h, document, other.resultId.?)).SemanticTokens;
    try testing.expectEqualSlices(u32, fresh.data, mismatched.data);

    try h.notify("textDocument/didClose", .{ .textDocument = document });
    try open(&h, document, "const alpha = true;\nconst text = \"hello\";\nfn use() void { _ = alpha; }\n");
    const reopened = (try delta(&h, document, mismatched.resultId.?)).SemanticTokens;
    try testing.expectEqualSlices(u32, fresh.data, reopened.data);
    try testing.expect(!std.mem.eql(u8, mismatched.resultId.?, reopened.resultId.?));
    try change(&h, document, "");
    const removed = (try delta(&h, document, reopened.resultId.?)).SemanticTokensDelta;
    try testing.expectEqual(1, removed.edits.len);
    try testing.expect(removed.edits[0].data == null);
    try testing.expectEqual(0, (try replay(&h, reopened.data, removed.edits)).len);
    try change(&h, document, source);
    const inserted = (try delta(&h, document, removed.resultId.?)).SemanticTokensDelta;
    try testing.expectEqual(1, inserted.edits.len);
    try testing.expectEqual(0, inserted.edits[0].deleteCount);
    const restored = try full(&h, document);
    try testing.expectEqualSlices(u32, restored.data, try replay(&h, &.{}, inserted.edits));
    _ = try h.request("shutdown", {});
}

test "semantic token ranges preserve document coordinates and full baselines in negotiated encodings" {
    inline for (.{ "utf-8", "utf-16", "utf-32" }) |encoding| {
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        const init = try initialize(&h, encoding, false);
        const selected = if (comptime std.mem.eql(u8, encoding, "utf-8")) "utf-8" else "utf-16";
        try testing.expectEqualStrings(selected, init.object.get("result").?.object.get("capabilities").?.object.get("positionEncoding").?.string);
        try open(&h, document, "// 😀\nconst @\"😀\" = \"😀\"; const after = @\"😀\";\n");
        const before = try full(&h, document);
        const column: u32 = if (comptime std.mem.eql(u8, encoding, "utf-8")) 30 else 26;
        const ranged = try decode(types.SemanticTokens, &h, try h.request("textDocument/semanticTokens/range", .{
            .textDocument = document,
            .range = types.Range{ .start = .{ .line = 1, .character = column + 1 }, .end = .{ .line = 1, .character = column + 2 } },
        }));
        try testing.expect(ranged.resultId == null);
        try testing.expectEqual(5, ranged.data.len);
        try testing.expectEqualSlices(u32, &.{ 1, column, 5 }, ranged.data[0..3]);
        const empty = try decode(types.SemanticTokens, &h, try h.request("textDocument/semanticTokens/range", .{
            .textDocument = document,
            .range = types.Range{ .start = .{ .line = 1, .character = column }, .end = .{ .line = 1, .character = column } },
        }));
        try testing.expectEqual(0, empty.data.len);
        const unchanged = (try delta(&h, document, before.resultId.?)).SemanticTokensDelta;
        try testing.expectEqual(0, unchanged.edits.len);
        _ = try h.request("shutdown", {});
    }
}

test "concurrent semantic full requests have unique ids and safe delta fallbacks" {
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try initialize(&h, "utf-16", false);
    try open(&h, document, "const value = 1;\nfn read() u32 { return value; }\n");
    var requests: [12]i64 = undefined;
    for (&requests) |*id| id.* = try h.send("textDocument/semanticTokens/full", .{ .textDocument = document });
    var results: [requests.len]types.SemanticTokens = undefined;
    for (requests, &results, 0..) |id, *result, index| {
        result.* = try decode(types.SemanticTokens, &h, try h.response(id));
        for (results[0..index]) |prior| try testing.expect(!std.mem.eql(u8, prior.resultId.?, result.resultId.?));
    }
    for (results) |prior| {
        const response = try delta(&h, document, prior.resultId.?);
        const current = switch (response) {
            .SemanticTokens => |tokens| tokens.data,
            .SemanticTokensDelta => |tokens| try replay(&h, prior.data, tokens.edits),
        };
        try testing.expectEqualSlices(u32, results[0].data, current);
    }
    _ = try h.request("shutdown", {});
}

fn refreshCount(h: *Harness) usize {
    var count: usize = 0;
    for (h.received.items) |message| if (message.object.get("method")) |method| {
        if (std.mem.eql(u8, method.string, "workspace/semanticTokens/refresh")) count += 1;
    };
    return count;
}

test "semantic refresh is capability gated and coalesces changes until the client responds" {
    inline for (.{ false, true }) |supported| {
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        _ = try initialize(&h, "utf-16", supported);
        h.hold_requests = true;
        try open(&h, document, "const value = 1;\n");
        try open(&h, other_document, "const other = 2;\n");
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expectEqual(@as(usize, if (supported) 1 else 0), refreshCount(&h));
        try change(&h, document, "const value = 3;\n");
        try change(&h, other_document, "const other = 4;\n");
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expectEqual(@as(usize, if (supported) 1 else 0), refreshCount(&h));
        if (supported) {
            h.hold_requests = false;
            try h.write(.{ .jsonrpc = "2.0", .id = "zig-analyzer/semanticTokensRefresh", .result = null });
            _ = try h.request("zig-analyzer/waitIdle", {});
            try testing.expectEqual(2, refreshCount(&h));
        }
        _ = try h.request("shutdown", {});
    }
}

test "semantic refresh retires delta baselines issued before it" {
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try initialize(&h, "utf-16", true);
    // Refresh requests are not answered automatically: changes in the meantime are merged into one
    // refresh, triggered by the reply below, and no more refreshes follow
    h.hold_requests = true;
    const source = "const value = 1;\nfn read() u32 { return value; }\n";
    try open(&h, document, source);
    try open(&h, other_document, "const other = 1;\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(1, refreshCount(&h));
    const before = try full(&h, document);
    try change(&h, other_document, "const other = 2;\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    try h.write(.{ .jsonrpc = "2.0", .id = "zig-analyzer/semanticTokensRefresh", .result = null });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(2, refreshCount(&h));
    // After a refresh the client may handle a range result first and replace the tokens it stores,
    // so results from before the refresh no longer serve as baselines
    const retired = (try delta(&h, document, before.resultId.?)).SemanticTokens;
    try testing.expectEqualSlices(u32, before.data, retired.data);
    const unchanged = (try delta(&h, document, retired.resultId.?)).SemanticTokensDelta;
    try testing.expectEqual(0, unchanged.edits.len);
    _ = try h.request("shutdown", {});
}

test "closed semantic token requests do not retain snapshots or reopen baselines" {
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try initialize(&h, "utf-16", false);
    const source = "const value = 1;\n";
    try open(&h, document, source);
    const first = try full(&h, document);
    try h.notify("textDocument/didClose", .{ .textDocument = document });
    const closed = (try delta(&h, document, first.resultId.?)).SemanticTokens;
    try testing.expect(closed.resultId == null);
    try testing.expectEqual(0, closed.data.len);
    const closed_full = try full(&h, document);
    try testing.expect(closed_full.resultId == null);
    try testing.expectEqual(0, h.server.semantic_cache.entries.count());
    try open(&h, document, source);
    const reopened = (try delta(&h, document, first.resultId.?)).SemanticTokens;
    try testing.expectEqualSlices(u32, first.data, reopened.data);
    try testing.expect(!std.mem.eql(u8, first.resultId.?, reopened.resultId.?));
    _ = try h.request("shutdown", {});
}

test "semantic token cancellation preserves baselines and close drains concurrent requests" {
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try initialize(&h, "utf-16", false);
    const source = "const value = 1;\nfn read() u32 { return value; }\n";
    try open(&h, document, source);
    const first = try full(&h, document);
    _ = try h.request("zig-analyzer/waitIdle", {});
    h.server.db.beginWrite();
    var writing = true;
    defer if (writing) h.server.db.endWrite();
    const canceled_full = try h.send("textDocument/semanticTokens/full", .{ .textDocument = document });
    const canceled_delta = try h.send("textDocument/semanticTokens/full/delta", .{ .textDocument = document, .previousResultId = first.resultId.? });
    try h.notify("$/cancelRequest", .{ .id = canceled_full });
    try h.notify("$/cancelRequest", .{ .id = canceled_delta });
    const barrier = try h.request("zig-analyzer/probe", {});
    try testing.expectEqual(-32601, barrier.object.get("error").?.object.get("code").?.integer);
    h.server.db.endWrite();
    writing = false;
    for ([_]i64{ canceled_full, canceled_delta }) |id| {
        const response = try h.response(id);
        try testing.expectEqual(-32800, response.object.get("error").?.object.get("code").?.integer);
    }
    const unchanged = (try delta(&h, document, first.resultId.?)).SemanticTokensDelta;
    try testing.expectEqual(0, unchanged.edits.len);
    var requests: [12]i64 = undefined;
    for (&requests, 0..) |*id, index| {
        id.* = if (index % 2 == 0)
            try h.send("textDocument/semanticTokens/full", .{ .textDocument = document })
        else
            try h.send("textDocument/semanticTokens/full/delta", .{ .textDocument = document, .previousResultId = unchanged.resultId.? });
    }
    try h.notify("textDocument/didClose", .{ .textDocument = document });
    var stale: std.ArrayList([]const u8) = .empty;
    for (requests) |id| {
        const response = try h.response(id);
        if (response.object.get("error")) |err| {
            try testing.expectEqual(-32801, err.object.get("code").?.integer);
        } else {
            const result = try decode(Cache.Result, &h, response);
            const result_id = switch (result) {
                .SemanticTokens => |tokens| tokens.resultId,
                .SemanticTokensDelta => |tokens| tokens.resultId,
            };
            if (result_id) |value| try stale.append(h.arena.allocator(), value);
        }
    }
    const closed = try full(&h, document);
    try testing.expect(closed.resultId == null);
    try testing.expectEqual(0, h.server.semantic_cache.entries.count());
    try open(&h, document, source);
    for (stale.items) |previous| {
        const reopened = (try delta(&h, document, previous)).SemanticTokens;
        try testing.expectEqualSlices(u32, first.data, reopened.data);
    }
    _ = try h.request("shutdown", {});
}

test "semantic token range boundaries are half open and invalid positions cannot mutate full baselines" {
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try initialize(&h, "utf-16", false);
    try open(&h, document, "const value = 1;\n");
    const first = try full(&h, document);
    const ranges: []const types.Range = &.{
        .{ .start = .{ .line = 0, .character = 6 }, .end = .{ .line = 0, .character = 6 } },
        .{ .start = .{ .line = 0, .character = 11 }, .end = .{ .line = 0, .character = 6 } },
        .{ .start = .{ .line = 50, .character = 0 }, .end = .{ .line = 60, .character = 100 } },
        .{ .start = .{ .line = 0, .character = 100 }, .end = .{ .line = 0, .character = 200 } },
    };
    for (ranges) |range| {
        const result = try decode(types.SemanticTokens, &h, try h.request("textDocument/semanticTokens/range", .{ .textDocument = document, .range = range }));
        try testing.expectEqual(0, result.data.len);
        try testing.expect(result.resultId == null);
    }
    const entire = try decode(types.SemanticTokens, &h, try h.request("textDocument/semanticTokens/range", .{
        .textDocument = document,
        .range = types.Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 100, .character = 100 } },
    }));
    try testing.expectEqualSlices(u32, first.data, entire.data);
    const invalid = try h.request("textDocument/semanticTokens/range", .{
        .textDocument = document,
        .range = .{ .start = .{ .line = -1, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
    });
    try testing.expectEqual(-32602, invalid.object.get("error").?.object.get("code").?.integer);
    const unchanged = (try delta(&h, document, first.resultId.?)).SemanticTokensDelta;
    try testing.expectEqual(0, unchanged.edits.len);
    _ = try h.request("shutdown", {});
}

test "semantic refresh handles client rejection without losing coalesced changes" {
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try initialize(&h, "utf-16", true);
    h.hold_requests = true;
    try open(&h, document, "const value = 1;\n");
    try open(&h, other_document, "const other = 1;\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(1, refreshCount(&h));
    try change(&h, document, "const value = 2;\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    try h.write(.{ .jsonrpc = "2.0", .id = "zig-analyzer/semanticTokensRefresh", .@"error" = .{ .code = -32603, .message = "rejected" } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(2, refreshCount(&h));
    try h.write(.{ .jsonrpc = "2.0", .id = "zig-analyzer/semanticTokensRefresh", .@"error" = .{ .code = -32603, .message = "rejected" } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(2, refreshCount(&h));
    h.hold_requests = false;
    try change(&h, document, "const value = 3;\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(3, refreshCount(&h));
    _ = try h.request("shutdown", {});
}

test "watched dependency changes refresh a sole open consumer and change its semantic classification" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dep.zig", .data = "pub const value = 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try initialize(&h, "utf-16", true);
    const arena = h.arena.allocator();
    const main_document: types.TextDocumentIdentifier = .{ .uri = try za.base.uri.fromPath(arena, try std.fs.path.join(arena, &.{ root, "main.zig" })) };
    const dep_uri = try za.base.uri.fromPath(arena, try std.fs.path.join(arena, &.{ root, "dep.zig" }));
    const source = "const dep = @import(\"dep.zig\");\nfn run() void { _ = dep.value; }\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.zig", .data = source });
    try open(&h, main_document, source);
    const before = try full(&h, main_document);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const before_refresh = refreshCount(&h);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dep.zig", .data = "pub const value = struct {};\n" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = dep_uri, .type = 2 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(before_refresh + 1, refreshCount(&h));
    // A result from before the refresh no longer serves as a baseline: the full tokens are returned
    const after = (try delta(&h, main_document, before.resultId.?)).SemanticTokens;
    try testing.expectEqual(before.data.len, after.data.len);
    var class_changes: usize = 0;
    for (before.data, after.data, 0..) |old, new, index| if (old != new) {
        try testing.expectEqual(3, index % 5);
        try testing.expectEqual(@backingInt(za.ide.semantic_tokens.TokenType.variable), old);
        try testing.expectEqual(@backingInt(za.ide.semantic_tokens.TokenType.@"struct"), new);
        class_changes += 1;
    };
    try testing.expectEqual(1, class_changes);
    try h.notify("textDocument/didClose", .{ .textDocument = main_document });
    const untracked = try full(&h, main_document);
    try testing.expect(untracked.resultId == null);
    try testing.expectEqualSlices(u32, after.data, untracked.data);
    try testing.expectEqual(0, h.server.semantic_cache.entries.count());
    _ = try h.request("shutdown", {});
}

test "semantic tokens remain single line nonoverlapping and within legend integer bounds" {
    const semantic = za.ide.semantic_tokens;
    inline for (.{ false, true }) |supported| {
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        _ = try h.request("initialize", .{
            .capabilities = .{ .textDocument = .{ .semanticTokens = .{
                .requests = .{ .full = true, .range = true },
                .tokenTypes = semantic.legend.tokenTypes,
                .tokenModifiers = semantic.legend.tokenModifiers,
                .formats = &[_][]const u8{"relative"},
                .overlappingTokenSupport = supported,
                .multilineTokenSupport = supported,
            } } },
        });
        const source = "// comment\nconst text =\n    \\\\first\n    \\\\second\n;\nfn run() void { _ = text; }\n";
        try open(&h, document, source);
        const tokens = try full(&h, document);
        try testing.expectEqual(0, tokens.data.len % 5);
        var line: u32 = 0;
        var column: u32 = 0;
        var previous_end: u32 = 0;
        var strings: usize = 0;
        var index: usize = 0;
        while (index < tokens.data.len) : (index += 5) {
            const token = tokens.data[index..][0..5];
            for (token) |value| try testing.expect(value <= std.math.maxInt(i32));
            line += token[0];
            if (token[0] != 0) {
                column = 0;
                previous_end = 0;
            }
            column += token[1];
            try testing.expect(column >= previous_end);
            try testing.expect(token[2] > 0);
            var lines = std.mem.splitScalar(u8, source, '\n');
            for (0..line) |_| _ = lines.next().?;
            const text = lines.next().?;
            previous_end = column + token[2];
            try testing.expect(previous_end <= text.len);
            try testing.expect(token[3] < semantic.legend.tokenTypes.len);
            try testing.expect(token[4] < @as(u32, 1) << @intCast(semantic.legend.tokenModifiers.len));
            if (token[3] == @backingInt(semantic.TokenType.string)) strings += 1;
        }
        try testing.expectEqual(2, strings);
        _ = try h.request("shutdown", {});
    }
}

test "semantic token settings apply to full delta and range requests and refresh when changed" {
    const semantic = za.ide.semantic_tokens;
    const T = semantic.TokenType;
    const M = semantic.Modifier;
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{
        .capabilities = .{ .workspace = .{ .semanticTokens = .{ .refreshSupport = true } } },
        .initializationOptions = .{ .diagnostics = .{ .debounce_ms = 0 }, .semantic_tokens = .{ .mode = "partial" } },
    });
    const source = "// comment\nvar counter: u32 = 0;\nfn bump() void { counter += 1; }\n";
    try open(&h, document, source);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const variable = @backingInt(T.variable);
    const function = @backingInt(T.function);
    const partial = try full(&h, document);
    try testing.expectEqualSlices(u32, &.{ 1, 4, 7, variable, M.declaration, 1, 3, 4, function, M.declaration, 0, 14, 7, variable, 0 }, partial.data);
    const unchanged = (try delta(&h, document, partial.resultId.?)).SemanticTokensDelta;
    try testing.expectEqual(0, unchanged.edits.len);
    const ranged = try decode(types.SemanticTokens, &h, try h.request("textDocument/semanticTokens/range", .{
        .textDocument = document,
        .range = types.Range{ .start = .{ .line = 2, .character = 0 }, .end = .{ .line = 3, .character = 0 } },
    }));
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4, function, M.declaration, 0, 14, 7, variable, 0 }, ranged.data);

    const refreshes = refreshCount(&h);
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .semantic_tokens = .{ .global_var = true } } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(refreshCount(&h) > refreshes);
    const current = switch (try delta(&h, document, unchanged.resultId.?)) {
        .SemanticTokens => |tokens| tokens.data,
        .SemanticTokensDelta => |tokens| try replay(&h, partial.data, tokens.edits),
    };
    const fresh = try full(&h, document);
    try testing.expectEqualSlices(u32, fresh.data, current);
    // Back to the full mode: the first token is the comment, and the `var` keyword is followed by a
    // declaration with `global`
    try testing.expectEqualSlices(u32, &.{ 0, 0, 10, @backingInt(T.comment), 0 }, fresh.data[0..5]);
    try testing.expectEqualSlices(u32, &.{ 1, 0, 3, @backingInt(T.keyword), 0, 0, 4, 7, variable, M.declaration | M.global }, fresh.data[5..15]);
    const marked = try decode(types.SemanticTokens, &h, try h.request("textDocument/semanticTokens/range", .{
        .textDocument = document,
        .range = types.Range{ .start = .{ .line = 2, .character = 17 }, .end = .{ .line = 2, .character = 18 } },
    }));
    try testing.expectEqualSlices(u32, &.{ 2, 17, 7, variable, M.global }, marked.data);
    _ = try h.request("shutdown", {});
}
