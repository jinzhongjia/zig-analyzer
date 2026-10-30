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

/// Hover text at the end of `needle` in `uri` (empty without a result)
fn hoverText(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    const result = try requestAt(h, "textDocument/hover", uri, text, needle, null);
    if (result != .object) return "";
    return result.object.get("contents").?.object.get("value").?.string;
}

test "a builtin.zig deleted from the cache keeps its target parameters" {
    const main_text = "pub const ptr_bytes = @sizeOf(usize);\n";
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = main_text }});
    defer project.deinit();
    const a = testing.allocator;
    // A 32-bit target, unlike the analyzer's own target used when no builtin.zig is known
    const shown = try std.process.run(a, testing.io, .{ .argv = &.{ project.env.zig_exe, "build-obj", "--show-builtin", "-target", "x86-linux" } });
    defer a.free(shown.stdout);
    defer a.free(shown.stderr);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "builtin.zig", .data = shown.stdout });

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const ha = h.arena.allocator();
    const builtin_path = try project.path(ha, "builtin.zig");
    const options = try std.json.Stringify.valueAlloc(ha, .{ .zig = .{ .builtin_path = builtin_path } }, .{});
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(ha, project.root), .capabilities = Empty{}, .initializationOptions = try std.json.parseFromSliceLeaky(std.json.Value, ha, options, .{}) });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(ha, try project.path(ha, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(std.mem.indexOf(u8, try hoverText(&h, main_uri, main_text, "ptr_by"), "= 4") != null);

    // The module graph is recomputed after the file is gone
    try project.tmp.dir.deleteFile(testing.io, "builtin.zig");
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &[_]Empty{}, .removed = &[_]Empty{} } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(std.mem.indexOf(u8, try hoverText(&h, main_uri, main_text, "ptr_by"), "= 4") != null);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

const examples_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) !void {
    \\    const mylib = b.addModule("mylib", .{ .root_source_file = b.path("src/mylib.zig"), .target = b.graph.host });
    \\    const check = b.step("check", "Check");
    \\    b.dependOnDirectoryContents(b.path("examples"));
    \\    var dir = try b.root.openDir(b.graph.io, "examples", .{ .iterate = true });
    \\    defer dir.close(b.graph.io);
    \\    var it = dir.iterate();
    \\    while (try it.next(b.graph.io)) |entry| {
    \\        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
    \\        const exe = b.addExecutable(.{ .name = b.dupe(entry.name[0 .. entry.name.len - 4]), .root_module = b.createModule(.{
    \\            .root_source_file = b.path(b.pathJoin(&.{ "examples", entry.name })),
    \\            .target = b.graph.host,
    \\            .imports = &.{.{ .name = "mylib", .module = mylib }},
    \\        }) });
    \\        check.dependOn(&exe.step);
    \\    }
    \\}
    \\
;
const examples_new =
    \\const mylib = @import("mylib");
    \\pub fn main() void {
    \\    const small: u8 = 300;
    \\    _ = small;
    \\    _ = mylib.greet();
    \\}
    \\
;

/// Waits until the server is idle and `cond(ctx)` holds; with the server watching files, the
/// change may be noticed only after a while. Fails after 60 seconds.
fn waitUntil(h: *Harness, ctx: anytype, comptime cond: fn (*Harness, @TypeOf(ctx)) anyerror!bool) !void {
    for (0..600) |_| {
        _ = try h.request("zig-analyzer/waitIdle", {});
        if (try cond(h, ctx)) return;
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.Timeout;
}

test "entries created in or deleted from a configure input directory reconfigure the project" {
    // `b.dependOnDirectoryContents` makes zig build rerun build.zig when the directory gains or
    // loses entries; a project that is not reconfigured keeps a stale build graph
    inline for (.{ true, false }) |client_watches| {
        var project = try fixture.Project.create(&.{
            .{ .path = "build.zig", .text = examples_build },
            .{ .path = "src/mylib.zig", .text = "pub fn greet() u32 {\n    return 1;\n}\n" },
            .{ .path = "examples/a.zig", .text = "const mylib = @import(\"mylib\");\npub fn main() void {\n    _ = mylib.greet();\n}\n" },
        });
        defer project.deinit();
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        const a = h.arena.allocator();
        const root_uri = try za.base.uri.fromPath(a, project.root);
        if (client_watches) {
            _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } } });
        } else {
            _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
        }
        try h.notify("initialized", Empty{});
        _ = try h.request("zig-analyzer/waitIdle", {});

        const new_path = try project.path(a, "examples/new.zig");
        const new_uri = try za.base.uri.fromPath(a, new_path);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = new_path, .data = examples_new });
        try open(&h, new_uri, examples_new);
        if (client_watches) try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = new_uri, .type = 1 }} });
        const Has = struct {
            fn error300(hh: *Harness, uri: []const u8) !bool {
                return lastHas(hh, uri, "cannot represent integer value '300'");
            }
            fn noError300(hh: *Harness, uri: []const u8) !bool {
                return !try lastHas(hh, uri, "cannot represent integer value '300'");
            }
        };
        try waitUntil(&h, new_uri, Has.error300);
        try testing.expectEqualStrings("mylib.zig", try gotoFile(&h, new_uri, examples_new, "mylib.gre"));

        try std.Io.Dir.cwd().deleteFile(testing.io, new_path);
        if (client_watches) try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = new_uri, .type = 3 }} });
        try waitUntil(&h, new_uri, Has.noError300);
        _ = try h.request("shutdown", {});
        try h.notify("exit", {});
    }
}
