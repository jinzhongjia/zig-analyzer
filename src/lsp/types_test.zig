const std = @import("std");
const types = @import("types.zig");
const json = std.json;
const testing = std.testing;

test "Params / Result types of all messages instantiate JSON parse and stringify" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (types.requests) |r| {
        try instantiate(r.Params, a);
        try instantiate(r.Result, a);
    }
    inline for (types.notifications) |n| try instantiate(n.Params, a);
}

/// `void` / `?void` 表示无参数或结果恒为 null，由 JSON-RPC 层处理
fn instantiate(comptime T: type, a: std.mem.Allocator) !void {
    if (T == void or T == ?void) return;
    _ = json.parseFromValueLeaky(T, a, .null, .{}) catch {};
    _ = try json.Stringify.valueAlloc(a, @as(?T, null), .{});
}

test "parse initialize request params" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const params = try json.parseFromSliceLeaky(types.InitializeParams, arena.allocator(),
        \\{"processId":123,"rootUri":"file:///tmp/x","capabilities":{
        \\  "general":{"positionEncodings":["utf-8","utf-16"]},
        \\  "textDocument":{"hover":{"contentFormat":["markdown","plaintext"]}},
        \\  "someVendorExtension":true},
        \\ "trace":"off","workspaceFolders":[{"uri":"file:///tmp/x","name":"x"}]}
    , .{ .ignore_unknown_fields = true });
    try testing.expectEqual(123, params.processId.?);
    try testing.expectEqualStrings("utf-8", params.capabilities.general.?.positionEncodings.?[0]);
    try testing.expectEqual(types.MarkupKind.markdown, params.capabilities.textDocument.?.hover.?.contentFormat.?[0]);
    try testing.expectEqual(types.TraceValue.off, params.trace.?);
}

test "stringify: integer enums as numbers, string literals and unions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts: json.Stringify.Options = .{ .emit_null_optional_fields = false };

    const sync: types.TextDocumentSyncOptions = .{ .openClose = true, .change = .Incremental };
    try testing.expectEqualStrings(
        \\{"openClose":true,"change":2}
    , try json.Stringify.valueAlloc(a, sync, opts));

    const create: types.CreateFile = .{ .uri = "file:///a" };
    try testing.expectEqualStrings(
        \\{"kind":"create","uri":"file:///a"}
    , try json.Stringify.valueAlloc(a, create, opts));

    // CreateFile | RenameFile | DeleteFile 等按 kind 字面量区分
    const Change = @typeInfo(@typeInfo(@FieldType(types.WorkspaceEdit, "documentChanges")).optional.child).pointer.child;
    const change = try json.parseFromSliceLeaky(Change, a,
        \\{"kind":"rename","oldUri":"file:///a","newUri":"file:///b"}
    , .{});
    try testing.expectEqualStrings("file:///b", change.RenameFile.newUri);
}
