//! End-to-end tests of the build system (maker) lifecycle: caches deleted during a session, failed
//! configurations and builds, and configure-time inputs. They start the server and the zig in PATH.

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};

fn open(h: *Harness, uri: []const u8, text: []const u8) !void {
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
}

/// Message texts of the last diagnostics published for `uri`
fn lastDiagnostics(h: *Harness, uri: []const u8) !?[]const []const u8 {
    var last: ?[]const []const u8 = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
        const diags = params.get("diagnostics").?.array.items;
        const texts = try h.arena.allocator().alloc([]const u8, diags.len);
        for (diags, texts) |d, *t| t.* = d.object.get("message").?.string;
        last = texts;
    }
    return last;
}

/// Whether the last diagnostics published for `uri` include one containing `needle`
fn lastHas(h: *Harness, uri: []const u8, needle: []const u8) !bool {
    const diags = (try lastDiagnostics(h, uri)) orelse return false;
    for (diags) |d| if (std.mem.indexOf(u8, d, needle) != null) return true;
    return false;
}

/// Starts the server on the project root with the given client capabilities
fn initialize(h: *Harness, root: []const u8) !void {
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, root), .capabilities = .{ .window = .{ .workDoneProgress = true } } });
    try h.notify("initialized", Empty{});
}

const options_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const opts = b.addOptions();
    \\    opts.addOption(u32, "x", 1);
    \\    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host, .optimize = .Debug });
    \\    mod.addOptions("build_options", opts);
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = mod });
    \\    const check = b.step("check", "check");
    \\    check.dependOn(&exe.step);
    \\}
    \\
;
const options_main =
    \\const std = @import("std");
    \\const opts = @import("build_options");
    \\pub fn main() void {
    \\    const small: u8 = 300;
    \\    std.debug.print("{d} {d}\n", .{ opts.x, small });
    \\}
    \\
;

test "deleting the local cache directory during a session restarts the build system" {
    // The maker keeps handles to the local cache directory it opened at startup: once it is
    // deleted, steps writing into it fail without errors, which must not clear compiler diagnostics
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = options_build },
        .{ .path = "src/main.zig", .text = options_main },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, project.root);
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, options_main);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(try lastHas(&h, main_uri, "cannot represent integer value '300'"));

    for (0..2) |_| {
        try project.tmp.dir.deleteTree(testing.io, ".zig-cache");
        try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expect(try lastHas(&h, main_uri, "cannot represent integer value '300'"));
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Position (0-based line and UTF-8 column) just after the first occurrence of `needle`
fn position(text: []const u8, needle: []const u8) struct { line: u32, character: u32 } {
    const offset = std.mem.indexOf(u8, text, needle).? + needle.len;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

/// Result of `method` at the end of `needle` in `uri`. A write transaction of background work
/// (indexing) answers a request with ContentModified: it is asked again once the server is idle.
fn requestAt(h: *Harness, method: []const u8, uri: []const u8, text: []const u8, needle: []const u8, new_name: ?[]const u8) !std.json.Value {
    for (0..50) |_| {
        const resp = if (new_name) |n|
            try h.request(method, .{ .textDocument = .{ .uri = uri }, .position = position(text, needle), .newName = n })
        else
            try h.request(method, .{ .textDocument = .{ .uri = uri }, .position = position(text, needle) });
        if (resp.object.get("result")) |r| return r;
        _ = try h.request("zig-analyzer/waitIdle", {});
    }
    return error.ContentModified;
}

/// File name of the goto result ("null" without a result)
fn gotoFile(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    const result = try requestAt(h, "textDocument/definition", uri, text, needle, null);
    if (result == .null) return "null";
    const target = switch (result) {
        .array => |list| if (list.items.len == 0) return "null" else list.items[0].object.get("uri").?.string,
        else => result.object.get("uri").?.string,
    };
    return target[std.mem.lastIndexOfScalar(u8, target, '/').? + 1 ..];
}

/// Names of the files a rename at `needle` in `uri` edits, sorted and joined with spaces
fn renamedFiles(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8, new_name: []const u8) ![]const u8 {
    const a = h.arena.allocator();
    const result = try requestAt(h, "textDocument/rename", uri, text, needle, new_name);
    if (result == .null) return "null";
    var names: std.ArrayList([]const u8) = .empty;
    if (result.object.get("changes")) |changes| {
        for (changes.object.keys()) |k| try names.append(a, k[std.mem.lastIndexOfScalar(u8, k, '/').? + 1 ..]);
    }
    if (result.object.get("documentChanges")) |changes| for (changes.array.items) |c| {
        const k = c.object.get("textDocument").?.object.get("uri").?.string;
        try names.append(a, k[std.mem.lastIndexOfScalar(u8, k, '/').? + 1 ..]);
    };
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return std.mem.join(a, " ", names.items);
}

const lib_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const lib = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = b.graph.host });
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"), .target = b.graph.host,
    \\        .imports = &.{.{ .name = "lib", .module = lib }} }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;
const lib_main =
    \\const lib = @import("lib");
    \\pub fn main() void {
    \\    _ = lib.value();
    \\}
    \\
;
const lib_lib = "pub fn value() u32 { return 42; }\n";
const lib_zon = ".{\n    .name = .app,\n    .version = \"0.0.1\",\n    .fingerprint = 0xc96e70cfdc04e3b6,\n    .paths = .{\"\"},\n}\n";

test "a configuration that fails after a restart keeps the previous build graph" {
    // Replacing the project by an instance without a build graph must not make named imports stop
    // resolving and rename miss their importers
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = lib_build },
        .{ .path = "build.zig.zon", .text = lib_zon },
        .{ .path = "src/main.zig", .text = lib_main },
        .{ .path = "src/lib.zig", .text = lib_lib },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, project.root);
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    const lib_uri = try za.base.uri.fromPath(a, try project.path(a, "src/lib.zig"));
    try open(&h, main_uri, lib_main);
    try open(&h, lib_uri, lib_lib);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("lib.zig", try gotoFile(&h, main_uri, lib_main, "lib.val"));

    // build.zig fails to compile, then build.zig.zon cannot be loaded
    const broken_build = try std.mem.replaceOwned(u8, a, lib_build, "{\n    const lib", "{\n    const x: u32 = \"oops\";\n    _ = x;\n    const lib");
    const broken_zon = try std.mem.replaceOwned(u8, a, lib_zon, ".name = .app", ".name = \"app\"");
    for ([_][2][]const u8{ .{ "build.zig", broken_build }, .{ "build.zig.zon", broken_zon } }) |broken| {
        const path = try project.path(a, broken[0]);
        const original = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = broken[1] });
        const uri = try za.base.uri.fromPath(a, path);
        try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
        _ = try h.request("zig-analyzer/waitIdle", {});
        if (std.mem.eql(u8, broken[0], "build.zig")) try testing.expect(try lastHas(&h, uri, "expected type 'u32'"));
        try testing.expectEqualStrings("lib.zig", try gotoFile(&h, main_uri, lib_main, "lib.val"));
        try testing.expectEqualStrings("lib.zig main.zig", try renamedFiles(&h, lib_uri, lib_lib, "fn val", "amount"));
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = original });
        try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expect(!try lastHas(&h, uri, "expected type 'u32'"));
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Messages of the `window/showMessage` notifications received so far
fn shownMessages(h: *Harness) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try h.notifications("window/showMessage")) |m| try out.append(h.arena.allocator(), m.object.get("params").?.object.get("message").?.string);
    return out.items;
}

/// Messages that ended the build progress (titled `zig build ...`) so far
fn buildProgressEnds(h: *Harness) ![]const []const u8 {
    const a = h.arena.allocator();
    var tokens: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList([]const u8) = .empty;
    for (try h.notifications("$/progress")) |m| {
        const params = m.object.get("params").?.object;
        const token = try std.json.Stringify.valueAlloc(a, params.get("token").?, .{});
        const value = params.get("value").?.object;
        const kind = value.get("kind").?.string;
        if (std.mem.eql(u8, kind, "begin")) {
            if (std.mem.startsWith(u8, value.get("title").?.string, "zig build")) try tokens.append(a, token);
        } else if (std.mem.eql(u8, kind, "end")) {
            for (tokens.items) |t| if (std.mem.eql(u8, t, token)) {
                try out.append(a, if (value.get("message")) |msg| msg.string else "");
                break;
            };
        }
    }
    return out.items;
}

test "a diagnostics step that fails without errors is reported, not shown as a clean build" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host });
        \\    mod.linkSystemLibrary("zanosuchlib", .{});
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = mod });
        \\    b.installArtifact(exe);
        \\    const check = b.step("check", "Check if app compiles");
        \\    check.dependOn(&exe.step);
        \\}
        \\
        },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, project.root);
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, "pub fn main() void {}\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    const shown = try shownMessages(&h);
    try testing.expectEqual(1, shown.len);
    try testing.expect(std.mem.indexOf(u8, shown[0], "compile exe app") != null);
    try testing.expect(std.mem.indexOf(u8, shown[0], "failed") != null);
    const ends = try buildProgressEnds(&h);
    try testing.expect(ends.len != 0);
    for (ends) |e| try testing.expect(!std.mem.eql(u8, e, "Done"));
    try testing.expect(std.mem.indexOf(u8, ends[ends.len - 1], "compile exe app") != null);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
