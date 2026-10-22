//! 自动导入补全的协议编辑须能直接应用，并在协商的位置编码下解析到目标声明。

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;
const offsets = za.util.offsets;
const types = za.lsp.types;
const Empty = struct {};

const source =
    \\// 许可说明
    \\//! 😀
    \\pub fn main() void {
    \\    const @"😀" = 0; _ = @"😀"; const value: Widgxx = .{ .size = 1 };
    \\    _ = value;
    \\}
    \\
;

fn position(text: []const u8, needle: []const u8, delta: u32, encoding: offsets.Encoding) !types.Position {
    const at: u32 = @intCast(std.mem.indexOf(u8, text, needle).?);
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    return lines.position(at + delta, encoding);
}

/// 第一次在可以自动导入的名字处补全时开始为自动导入建索引：这时还没有自动导入，结果标记为不完整。等索引建完
fn startAutoImport(h: *Harness, uri: []const u8, at: types.Position) !void {
    const first = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = at });
    try testing.expect(first.object.get("result").?.object.get("isIncomplete").?.bool);
    _ = try h.request("zig-analyzer/waitIdle", {});
}

fn completionItems(response: std.json.Value) []const std.json.Value {
    const result = response.object.get("result").?;
    return if (result == .array) result.array.items else result.object.get("items").?.array.items;
}

fn importedWidget(response: std.json.Value) ?std.json.Value {
    for (completionItems(response)) |item| {
        if (!std.mem.eql(u8, item.object.get("label").?.string, "Widget")) continue;
        if (item.object.get("additionalTextEdits") != null) return item;
    }
    return null;
}

/// `zig-analyzer/status` 中各自动导入 query 的 key 总数
fn importQueryKeys(response: std.json.Value) i64 {
    var keys: i64 = 0;
    for (response.object.get("result").?.object.get("queries").?.array.items) |q| {
        const name = q.object.get("name").?.string;
        if (std.mem.indexOf(u8, name, ".imports.") == null) continue;
        keys += q.object.get("keys").?.integer;
    }
    return keys;
}

fn applyCompletion(a: std.mem.Allocator, text: []const u8, item: std.json.Value, encoding: offsets.Encoding) ![]const u8 {
    const Change = struct { start: usize, end: usize, text: []const u8 };
    var changes: std.ArrayList(Change) = .empty;
    const additional: []const std.json.Value = if (item.object.get("additionalTextEdits")) |edits| edits.array.items else &.{};
    for (0..additional.len + 1) |i| {
        const value = if (i == 0) item.object.get("textEdit").? else additional[i - 1];
        const edit = try std.json.parseFromValueLeaky(types.TextEdit, a, value, .{});
        try changes.append(a, .{
            .start = offsets.positionToOffset(text, edit.range.start, encoding),
            .end = offsets.positionToOffset(text, edit.range.end, encoding),
            .text = edit.newText,
        });
    }
    std.mem.sort(Change, changes.items, {}, struct {
        fn less(_: void, left: Change, right: Change) bool {
            return left.start < right.start;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (changes.items) |change| {
        try testing.expect(cursor <= change.start);
        try out.appendSlice(a, text[cursor..change.start]);
        try out.appendSlice(a, change.text);
        cursor = change.end;
    }
    try out.appendSlice(a, text[cursor..]);
    return out.items;
}

test "auto-import edits replace the whole identifier and resolve after application in both encodings" {
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/lib.zig", .text = "pub const Widget = struct { size: u32 };\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    for ([_]offsets.Encoding{ .utf8, .utf16 }) |encoding| {
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        const a = h.arena.allocator();
        const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
        _ = try h.request("initialize", .{
            .rootUri = try za.base.uri.fromPath(a, project.root),
            .capabilities = .{ .general = .{ .positionEncodings = &[_][]const u8{encoding.toLsp()} } },
            .initializationOptions = .{
                .diagnostics = .{ .compiler = false, .inactive_code = false },
                .files = .{ .watcher = "client" },
            },
        });
        try h.notify("initialized", Empty{});
        try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = source } });
        _ = try h.request("zig-analyzer/waitIdle", {});
        const params = .{ .textDocument = .{ .uri = uri }, .position = try position(source, "Widgxx", 4, encoding) };
        // 补全之前不建自动导入的索引
        try testing.expect(importedWidget(try h.request("textDocument/completion", params)) == null);
        _ = try h.request("zig-analyzer/waitIdle", {});
        const response = try h.request("textDocument/completion", params);
        const item = importedWidget(response) orelse return error.MissingAutoImport;
        const edited = try applyCompletion(a, source, item, encoding);
        try testing.expect(std.mem.indexOf(u8, edited, "Widgxx") == null);
        try testing.expect(std.mem.indexOf(u8, edited, "const value: Widget =") != null);
        try testing.expect(std.mem.startsWith(u8, edited, "// 许可说明\n//! 😀\nconst Widget = @import(\"lib\").Widget;"));
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = &.{.{ .text = edited }} });
        _ = try h.request("zig-analyzer/waitIdle", {});
        const target = try h.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = try position(edited, ".size", 2, encoding) });
        const result = target.object.get("result").?;
        try testing.expect(result != .null);
        const location = if (result == .array) result.array.items[0] else result;
        const lib_uri = try za.base.uri.fromPath(a, try project.path(a, "src/lib.zig"));
        try testing.expectEqualStrings(lib_uri, location.object.get("uri").?.string);

        try h.notify("workspace/didChangeConfiguration", .{ .settings = .{
            .completion = .{ .auto_import = false },
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        } });
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 3 }, .contentChanges = &.{.{ .text = source }} });
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expect(importedWidget(try h.request("textDocument/completion", params)) == null);
        try h.notify("workspace/didChangeConfiguration", .{ .settings = .{
            .completion = .{ .auto_import = true },
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        } });
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expect(importedWidget(try h.request("textDocument/completion", params)) != null);
        _ = try h.request("shutdown", {});
    }
}

test "auto-import indexing restarts when an earlier pass did not finish" {
    // 一轮索引没有建完（出错、任务没能启动）之后，补全请求重新开始建索引，不会一直不提供自动导入
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/lib.zig", .text = "pub const Widget = struct { size: u32 };\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, project.root),
        .capabilities = Empty{},
        .initializationOptions = .{
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        },
    });
    try h.notify("initialized", Empty{});
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = source } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const params = .{ .textDocument = .{ .uri = uri }, .position = try position(source, "Widgxx", 4, .utf16) };
    try startAutoImport(&h, uri, params.position);
    try testing.expect(importedWidget(try h.request("textDocument/completion", params)) != null);
    h.server.imports_basis.store(std.math.maxInt(u64), .release);
    const pending = try h.request("textDocument/completion", params);
    try testing.expect(pending.object.get("result").?.object.get("isIncomplete").?.bool);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(importedWidget(try h.request("textDocument/completion", params)) != null);
    _ = try h.request("shutdown", {});
}

test "auto-import works in an unsaved untitled document" {
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/lib.zig", .text = "pub const Widget = struct { size: u32 };\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, project.root),
        .capabilities = Empty{},
        .initializationOptions = .{
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        },
    });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-1";
    const text = "pub fn main() void { _ = ArrayL; }\n";
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const at = try position(text, "ArrayL", 6, .utf16);
    try startAutoImport(&h, uri, at);
    const response = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = at });
    const item = for (completionItems(response)) |candidate| {
        if (!std.mem.eql(u8, candidate.object.get("label").?.string, "ArrayList")) continue;
        if (candidate.object.get("additionalTextEdits") != null) break candidate;
    } else return error.MissingUntitledAutoImport;
    try testing.expect(item.object.get("data") != null);
    _ = try h.request("shutdown", {});
}

test "disabled auto-import does not build or query the import index" {
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/lib.zig", .text = "pub const Widget = struct { size: u32 };\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, project.root),
        .capabilities = Empty{},
        .initializationOptions = .{
            .completion = .{ .auto_import = false },
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        },
    });
    try h.notify("initialized", Empty{});
    const text = "pub fn main() void { _ = Widg; }\n";
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const response = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = try position(text, "Widg", 4, .utf16) });
    try testing.expect(response.object.get("result").? == .array);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), h.server.imports_basis.load(.acquire));
    try testing.expect(!h.server.imports_wanted.load(.acquire));
    try testing.expectEqual(@as(i64, 0), importQueryKeys(try h.request("zig-analyzer/status", {})));
    _ = try h.request("shutdown", {});
}

test "auto-import items resolve to the signature, docs and where the target is defined" {
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/lib.zig", .text = "/// A widget.\npub const Widget = struct { size: u32 };\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    const init = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, project.root),
        .capabilities = Empty{},
        .initializationOptions = .{
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        },
    });
    const provider = init.object.get("result").?.object.get("capabilities").?.object.get("completionProvider").?;
    try testing.expect(provider.object.get("resolveProvider").?.bool);
    try h.notify("initialized", Empty{});
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = source } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const at = try position(source, "Widgxx", 4, .utf16);
    try startAutoImport(&h, uri, at);
    const item = importedWidget(try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = at })).?;
    try testing.expect(item.object.get("data") != null);
    const resolved = (try h.request("completionItem/resolve", item)).object.get("result").?;
    try testing.expectEqualStrings("const Widget = struct", resolved.object.get("detail").?.string);
    try testing.expectEqualStrings("A widget.\n\nDefined in `lib/lib.zig:2`", resolved.object.get("documentation").?.object.get("value").?.string);
    // 原有的编辑保持不变
    try testing.expect(resolved.object.get("additionalTextEdits") != null);
    _ = try h.request("shutdown", {});
}

test "completion does not run auto-import indexing inside its read transaction" {
    // 不能另起任务时任务就地执行：补全持有读事务，索引在其中就地执行时，编辑的写事务与之互相等待
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var h: Harness = undefined;
    try h.startIo(threaded.io());
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-1";
    const text = "pub fn main() void {\n    _ = st;\n}\n";
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // 服务器空闲时修改：补全请求与它要启动的任务都不能另起，只能就地执行
    threaded.concurrent_limit = .nothing;
    errdefer threaded.concurrent_limit = .unlimited;
    const response = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = try position(text, "st;", 2, .utf16) });
    try testing.expect(response.object.get("result").?.object.get("isIncomplete").?.bool);
    try testing.expectEqual(std.math.maxInt(u64), h.server.imports_basis.load(.acquire));
    const busy = blk: {
        h.server.busy_mutex.lockUncancelable(testing.io);
        defer h.server.busy_mutex.unlock(testing.io);
        const n = h.server.busy;
        // 计数泄漏时 deinit 中的 waitIdle 永远等待：先归零，让失败的测试正常结束
        h.server.busy = 0;
        break :blk n;
    };
    try testing.expectEqual(0, busy);
    threaded.concurrent_limit = .unlimited;
    _ = try h.request("shutdown", {});
}

test "auto-import module and file candidates resolve through completionItem/resolve" {
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/Util.zig", .text = "//! Utilities.\npub const Service = u32;\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, project.root),
        .capabilities = Empty{},
        .initializationOptions = .{
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        },
    });
    try h.notify("initialized", Empty{});
    const text = "fn catalog() void { _ = @import(\"Util.zig\"); }\npub fn main() void { _ = Uti; }\n";
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const at = try position(text, "_ = Uti", 7, .utf16);
    try startAutoImport(&h, uri, at);
    const response = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = at });
    const item = for (completionItems(response)) |candidate| {
        if (!std.mem.eql(u8, candidate.object.get("label").?.string, "Util")) continue;
        if (candidate.object.get("additionalTextEdits") != null) break candidate;
    } else return error.MissingFileCandidate;
    try testing.expect(item.object.get("data") != null);
    const resolved = (try h.request("completionItem/resolve", item)).object.get("result").?;
    try testing.expectEqualStrings("@import(\"Util.zig\")", resolved.object.get("detail").?.string);
    try testing.expectEqualStrings("Utilities.\n\nFile `Util.zig`", resolved.object.get("documentation").?.object.get("value").?.string);
    // 不是本服务器给出的 data：原样返回，不报错
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "from", .{ .integer = 999999 });
    const malformed = types.CompletionItem{ .label = "Util", .data = .{ .object = data } };
    const unchanged = (try h.request("completionItem/resolve", malformed)).object.get("result").?;
    try testing.expect(unchanged.object.get("detail") == null);
    try testing.expectEqualStrings("Util", unchanged.object.get("label").?.string);
    _ = try h.request("shutdown", {});
}

test "auto-import completion reports truncation and recomputes for a narrower prefix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var library: std.ArrayList(u8) = .empty;
    for (0..140) |i| try library.print(a, "pub const Widget{d:0>3} = u8;\n", .{i});
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/lib.zig", .text = library.items },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, project.root),
        .capabilities = Empty{},
        .initializationOptions = .{
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        },
    });
    try h.notify("initialized", Empty{});
    const broad = "pub fn main() void { _ = Widget; }\n";
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = broad } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try startAutoImport(&h, uri, try position(broad, "Widget", 6, .utf16));
    const response = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = try position(broad, "Widget", 6, .utf16) });
    try testing.expect(response.object.get("result").?.object.get("isIncomplete").?.bool);
    var truncated: usize = 0;
    var saw_000 = false;
    var saw_139 = false;
    for (completionItems(response)) |item| {
        if (item.object.get("additionalTextEdits") == null) continue;
        truncated += 1;
        const label = item.object.get("label").?.string;
        if (std.mem.eql(u8, label, "Widget000")) saw_000 = true;
        if (std.mem.eql(u8, label, "Widget139")) saw_139 = true;
    }
    try testing.expectEqual(@as(usize, 128), truncated);
    try testing.expect(saw_000);
    try testing.expect(!saw_139);
    const narrow = "pub fn main() void { _ = Widget139; }\n";
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = &.{.{ .text = narrow }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const narrowed = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = try position(narrow, "Widget139", 9, .utf16) });
    const result = narrowed.object.get("result").?;
    if (result == .object) try testing.expect(!result.object.get("isIncomplete").?.bool);
    for (completionItems(narrowed)) |item| {
        if (!std.mem.eql(u8, item.object.get("label").?.string, "Widget139")) continue;
        try testing.expect(item.object.get("additionalTextEdits") != null);
        break;
    } else return error.MissingNarrowedAutoImport;
    _ = try h.request("shutdown", {});
}

test "auto-import storage public paths and direct aliases resolve after applying edits" {
    const initial =
        \\fn catalog() void { _ = @import("Provider.zig"); }
        \\pub fn main() void {}
        \\
    ;
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = initial },
        .{ .path = "src/lib.zig", .text = "pub extern const external_counter: u32;\npub const EdgeWidget = struct { tag: u8 };\n" },
        .{ .path = "src/Provider.zig", .text = "const Hidden = struct { pub const ReviewWidget = struct { tag: u8 }; };\npub const PublicAPI = Hidden;\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, project.root),
        .capabilities = .{ .general = .{ .positionEncodings = &[_][]const u8{"utf-8"} } },
        .initializationOptions = .{
            .diagnostics = .{ .compiler = false, .inactive_code = false },
            .files = .{ .watcher = "client" },
        },
    });
    try h.notify("initialized", Empty{});
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = initial } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const Case = struct {
        source: []const u8,
        needle: []const u8,
        filter: []const u8,
        target: []const u8,
        target_name: []const u8,
        alias: bool = false,
        readonly: bool = false,
    };
    const cases = [_]Case{
        .{
            .source = "pub fn main() void { _ = externa; }\n",
            .needle = "externa",
            .filter = "external_counter",
            .target = "src/lib.zig",
            .target_name = "external_counter",
            .readonly = true,
        },
        .{
            .source = "fn catalog() void { _ = @import(\"Provider.zig\"); }\npub fn main() void { const value: ReviewWidg = .{ .tag = 1 }; _ = value.tag; }\n",
            .needle = "const value: ReviewWidg",
            .filter = "ReviewWidget",
            .target = "src/Provider.zig",
            .target_name = ".tag",
        },
        .{
            .source = "const Renamed = @import(\"lib\").EdgeWidget;\npub fn main() void { const value: EdgeWidg = .{ .tag = 1 }; _ = value.tag; }\n",
            .needle = "const value: EdgeWidg",
            .filter = "EdgeWidget",
            .target = "src/lib.zig",
            .target_name = ".tag",
            .alias = true,
        },
        .{
            .source = "const Renamed = @import(\"lib\").EdgeWidget;\npub fn main() void {\n    const value: @\"EdgeWidg\n        = .{ .tag = 1 }; _ = value.tag;\n}\n",
            .needle = "const value: @\"EdgeWidg",
            .filter = "@\"EdgeWidg",
            .target = "src/lib.zig",
            .target_name = ".tag",
            .alias = true,
        },
    };
    var version: i64 = 2;
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = cases[0].source }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try startAutoImport(&h, uri, try position(cases[0].source, cases[0].needle, @intCast(cases[0].needle.len), .utf8));
    for (cases) |case| {
        version += 1;
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = case.source }} });
        _ = try h.request("zig-analyzer/waitIdle", {});
        const cursor = try position(case.source, case.needle, @intCast(case.needle.len), .utf8);
        const response = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = cursor });
        const item = for (completionItems(response)) |candidate| {
            const filter = candidate.object.get("filterText") orelse continue;
            if (std.mem.startsWith(u8, filter.string, case.filter)) break candidate;
        } else return error.MissingEdgeCompletion;
        const edit = try std.json.parseFromValueLeaky(types.TextEdit, a, item.object.get("textEdit").?, .{});
        try testing.expectEqual(edit.range.start.line, edit.range.end.line);
        if (case.readonly) try testing.expectEqual(@as(i64, @backingInt(types.CompletionItemKind.Constant)), item.object.get("kind").?.integer);
        if (case.alias) {
            try testing.expectEqualStrings("Renamed", item.object.get("label").?.string);
            try testing.expect(item.object.get("additionalTextEdits") == null);
            var aliases: usize = 0;
            for (completionItems(response)) |candidate| if (std.mem.eql(u8, candidate.object.get("label").?.string, "Renamed")) {
                aliases += 1;
            };
            try testing.expectEqual(@as(usize, 1), aliases);
        }
        const edited = try applyCompletion(a, case.source, item, .utf8);
        version += 1;
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = edited }} });
        _ = try h.request("zig-analyzer/waitIdle", {});
        const target = try h.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = try position(edited, case.target_name, 2, .utf8) });
        const result = target.object.get("result").?;
        try testing.expect(result != .null);
        const location = if (result == .array) result.array.items[0] else result;
        try testing.expectEqualStrings(try za.base.uri.fromPath(a, try project.path(a, case.target)), location.object.get("uri").?.string);
    }
    _ = try h.request("shutdown", {});
}
