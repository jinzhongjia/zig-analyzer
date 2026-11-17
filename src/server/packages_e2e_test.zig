//! End-to-end: the `zig-analyzer/packages` inspection request, and the dependency hash code action
//! (`zig-analyzer/fetchDependencyHash`) that runs `zig fetch` and applies the edit.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const Harness = @import("test_harness.zig").Harness;

/// Empty object (`.{}` is an empty tuple, which would be serialized as `[]`)
const Empty = struct {};

const literal_actions = .{ .codeAction = .{ .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = &[_][]const u8{"quickfix"} } } } };

fn initialize(h: *Harness, root: []const u8, apply_edit: bool) !void {
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), root);
    _ = try h.request("initialize", .{
        .rootUri = root_uri,
        .capabilities = .{
            .workspace = .{ .applyEdit = apply_edit },
            .textDocument = .{ .codeAction = .{ .codeActionLiteralSupport = literal_actions.codeAction.codeActionLiteralSupport } },
        },
    });
    try h.notify("initialized", Empty{});
}

fn shutdown(h: *Harness) !void {
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

fn result(h: *Harness, method: []const u8, params: anytype) !std.json.Value {
    const response = try h.request(method, params);
    return response.object.get("result") orelse return error.TestUnexpectedResult;
}

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return value.object.get(name) orelse .null;
}

fn string(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// The 0-based line and byte column of `offset` in `text`
fn position(text: []const u8, offset: usize) struct { line: u32, character: u32 } {
    var line: u32 = 0;
    var line_start: usize = 0;
    for (text[0..offset], 0..) |c, i| if (c == '\n') {
        line += 1;
        line_start = i + 1;
    };
    return .{ .line = line, .character = @intCast(offset - line_start) };
}

test "packages: manifest fields and resolved dependency directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const zon =
        \\.{
        \\    .name = .pkg,
        \\    .version = "1.2.3",
        \\    .fingerprint = 0x1234567890abcdef,
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{
        \\        .lib = .{
        \\            .url = "https://example.com/lib.tar.gz",
        \\            .hash = "lib-0.1.0-AAAA",
        \\        },
        \\        .local = .{ .path = "local" },
        \\    },
        \\    .paths = .{ "src", "build.zig" },
        \\}
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig.zon", .data = zon });
    try tmp.dir.createDirPath(testing.io, "zig-pkg/lib-0.1.0-AAAA");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-pkg/lib-0.1.0-AAAA/build.zig.zon", .data = "{}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-pkg/lib-0.1.0-AAAA/build.zig", .data = "" });
    try tmp.dir.createDirPath(testing.io, "local");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "local/build.zig.zon", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const a = testing.allocator;

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, root, false);
    const projects = (try result(&h, "zig-analyzer/packages", {}));
    const list = field(projects, "projects").array.items;
    try testing.expectEqual(1, list.len);
    const project = list[0];
    try testing.expectEqualStrings(root, string(field(project, "root")).?);
    try testing.expectEqualStrings("pkg", string(field(project, "name")).?);
    try testing.expectEqualStrings("1.2.3", string(field(project, "version")).?);
    try testing.expectEqualStrings("0x1234567890abcdef", string(field(project, "fingerprint")).?);
    try testing.expectEqualStrings("0.17.0", string(field(project, "minimum_zig_version")).?);
    const paths = field(project, "paths").array.items;
    try testing.expectEqual(2, paths.len);
    try testing.expectEqualStrings("src", paths[0].string);
    try testing.expectEqualStrings("build.zig", paths[1].string);

    const deps = field(project, "dependencies").array.items;
    try testing.expectEqual(2, deps.len);
    const lib = deps[0];
    try testing.expectEqualStrings("lib", string(field(lib, "name")).?);
    try testing.expectEqualStrings("url", string(field(lib, "kind")).?);
    try testing.expectEqualStrings("https://example.com/lib.tar.gz", string(field(lib, "url")).?);
    try testing.expectEqualStrings("lib-0.1.0-AAAA", string(field(lib, "hash")).?);
    try testing.expectEqual(true, field(lib, "exists").bool);
    try testing.expect(std.mem.endsWith(u8, string(field(lib, "manifest")).?, "build.zig.zon"));
    try testing.expect(std.mem.endsWith(u8, string(field(lib, "build_zig")).?, "build.zig"));
    const expected_lib = try std.fs.path.join(a, &.{ root, "zig-pkg", "lib-0.1.0-AAAA" });
    defer a.free(expected_lib);
    try testing.expectEqualStrings(expected_lib, string(field(lib, "root")).?);

    const local = deps[1];
    try testing.expectEqualStrings("local", string(field(local, "name")).?);
    try testing.expectEqualStrings("path", string(field(local, "kind")).?);
    try testing.expectEqualStrings("local", string(field(local, "path")).?);
    try testing.expectEqual(true, field(local, "exists").bool);
    const expected_local = try std.fs.path.join(a, &.{ root, "local" });
    defer a.free(expected_local);
    try testing.expectEqualStrings(expected_local, string(field(local, "root")).?);

    try shutdown(&h);
}

test "dependency hash: code action, zig fetch, and the applied edit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const zon =
        \\.{
        \\    .name = .pkg,
        \\    .dependencies = .{
        \\        .lib = .{ .url = "https://example.com/lib.tar.gz" },
        \\    },
        \\    .paths = .{""},
        \\}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig.zon", .data = zon });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // Wraps the real zig for everything but `fetch`; `fetch` records its URL and prints a hash
    const script = try std.fmt.allocPrint(testing.allocator,
        \\#!/bin/sh
        \\if [ "$1" = fetch ]; then
        \\    printf '%s' "$2" > "{s}/fetched-url"
        \\    printf 'lib-0.1.0-AAAA\n'
        \\    exit 0
        \\fi
        \\exec zig "$@"
        \\
    , .{root});
    defer testing.allocator.free(script);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });

    const manifest_path = try std.fs.path.join(testing.allocator, &.{ root, "build.zig.zon" });
    defer testing.allocator.free(manifest_path);
    const manifest_uri = try za.base.uri.fromPath(testing.allocator, manifest_path);
    defer testing.allocator.free(manifest_uri);

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const settings = try std.fmt.allocPrint(a, "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{root});
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, root),
        .capabilities = .{
            .workspace = .{ .applyEdit = true },
            .textDocument = .{ .codeAction = .{ .codeActionLiteralSupport = literal_actions.codeAction.codeActionLiteralSupport } },
        },
        .initializationOptions = try std.json.parseFromSliceLeaky(std.json.Value, a, settings, .{}),
    });
    try h.notify("initialized", Empty{});
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = manifest_uri, .languageId = "zon", .version = 1, .text = zon } });

    const url_at = std.mem.indexOf(u8, zon, "https://example.com/lib.tar.gz").?;
    const url_end = url_at + "https://example.com/lib.tar.gz".len + 1;
    const cursor = position(zon, url_at + 2);
    const actions = (try result(&h, "textDocument/codeAction", .{
        .textDocument = .{ .uri = manifest_uri },
        .range = .{ .start = .{ .line = cursor.line, .character = cursor.character }, .end = .{ .line = cursor.line, .character = cursor.character } },
        .context = .{ .diagnostics = &.{} },
    })).array.items;
    var action: ?std.json.Value = null;
    for (actions) |candidate| {
        const title = string(field(candidate, "title")) orelse continue;
        if (std.mem.startsWith(u8, title, "fetch hash for `lib`")) action = candidate;
    }
    try testing.expect(action != null);
    const command = field(action.?, "command");
    try testing.expectEqualStrings("zig-analyzer/fetchDependencyHash", string(field(command, "command")).?);
    const arguments = field(command, "arguments").array.items;
    try testing.expectEqual(1, arguments.len);
    try testing.expectEqualStrings(manifest_uri, string(field(arguments[0], "uri")).?);
    try testing.expectEqualStrings("lib", string(field(arguments[0], "dependency")).?);
    try testing.expectEqualStrings("https://example.com/lib.tar.gz", string(field(arguments[0], "url")).?);

    _ = try h.request("workspace/executeCommand", .{
        .command = string(field(command, "command")).?,
        .arguments = arguments,
    });

    // `zig fetch` ran in the manifest's directory and got the URL
    const fetched = try tmp.dir.readFileAlloc(testing.io, "fetched-url", a, .limited(1024));
    try testing.expectEqualStrings("https://example.com/lib.tar.gz", fetched);

    // The command sent the edit to the client with `workspace/applyEdit`
    var edit: ?std.json.Value = null;
    for (h.received.items) |message| {
        const method = message.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "workspace/applyEdit")) edit = message;
    }
    try testing.expect(edit != null);
    const changes = field(field(edit.?, "params"), "edit");
    const edits = field(changes, "changes").object.get(manifest_uri).?.array.items;
    try testing.expectEqual(1, edits.len);
    const text_edit = edits[0];
    try testing.expectEqualStrings(", .hash = \"lib-0.1.0-AAAA\"", string(field(text_edit, "newText")).?);
    const start = field(text_edit, "range");
    const expected = position(zon, url_end);
    try testing.expectEqual(expected.line, field(field(start, "start"), "line").integer);
    try testing.expectEqual(expected.character, field(field(start, "start"), "character").integer);
    try testing.expectEqual(expected.line, field(field(start, "end"), "line").integer);
    try testing.expectEqual(expected.character, field(field(start, "end"), "character").integer);

    try shutdown(&h);
}
