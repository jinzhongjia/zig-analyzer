//! End-to-end: external changes on disk, adding and removing workspace folders, unsaved documents
//! (`untitled:`), and starting, restarting and stopping projects.

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;
const Server = @import("Server.zig");
const Workspace = @import("Workspace.zig");

const Empty = struct {};

fn position(text: []const u8, needle: []const u8) struct { line: u32, character: u32 } {
    const offset = std.mem.indexOf(u8, text, needle).? + needle.len;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

fn completionLabels(h: *Harness, uri: []const u8, text: []const u8, after: []const u8) ![]const u8 {
    const resp = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = position(text, after) });
    var labels: std.ArrayList([]const u8) = .empty;
    const result = resp.object.get("result").?;
    if (result == .array) for (result.array.items) |item| try labels.append(h.arena.allocator(), item.object.get("label").?.string);
    return std.mem.join(h.arena.allocator(), " ", labels.items);
}

fn open(h: *Harness, uri: []const u8, text: []const u8) !void {
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
}

/// Message texts of the last diagnostics published for `uri`
fn lastDiagnostics(h: *Harness, uri: []const u8) !?[]const []const u8 {
    var last: ?[]const []const u8 = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
        var messages: std.ArrayList([]const u8) = .empty;
        for (params.get("diagnostics").?.array.items) |d| try messages.append(h.arena.allocator(), d.object.get("message").?.string);
        last = messages.items;
    }
    return last;
}

test "external changes on disk are picked up through didChangeWatchedFiles" {
    const main_text = "const lib = @import(\"lib.zig\");\npub fn main() void {\n    lib.\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "lib.zig", .text = "pub fn hello() void {}\n" },
        .{ .path = "other.zig", .text = "pub fn first() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } } });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    const lib_path = try project.path(a, "lib.zig");
    const lib_uri = try za.base.uri.fromPath(a, lib_path);
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});

    // File watching was registered dynamically
    var registered = false;
    for (h.received.items) |m| {
        const method = m.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "client/registerCapability")) continue;
        for (m.object.get("params").?.object.get("registrations").?.array.items) |r| {
            if (std.mem.eql(u8, r.object.get("method").?.string, "workspace/didChangeWatchedFiles")) registered = true;
        }
    }
    try testing.expect(registered);
    try testing.expectEqualStrings("hello", try completionLabels(&h, main_uri, main_text, "    lib."));

    // Rewrite lib.zig outside the editor
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = lib_path, .data = "pub fn goodbye() void {}\n" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = lib_uri, .type = 2 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("goodbye", try completionLabels(&h, main_uri, main_text, "    lib."));

    // Delete
    try std.Io.Dir.cwd().deleteFile(testing.io, lib_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = lib_uri, .type = 3 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("", try completionLabels(&h, main_uri, main_text, "    lib."));

    // For open files the buffer is authoritative
    const other_text = "const other = @import(\"other.zig\");\ntest {\n    other.\n}\n";
    const other_path = try project.path(a, "other.zig");
    const other_uri = try za.base.uri.fromPath(a, other_path);
    const user_uri = try za.base.uri.fromPath(a, try project.path(a, "user.zig"));
    try open(&h, user_uri, other_text);
    try open(&h, other_uri, "pub fn fromBuffer() void {}\n");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = other_path, .data = "pub fn fromDisk() void {}\n" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = other_uri, .type = 2 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("fromBuffer", try completionLabels(&h, user_uri, other_text, "    other."));

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "without file watching from the client, the server watches files on disk" {
    const main_text =
        \\const lib = @import("lib.zig");
        \\const deep = @import("sub/deep.zig");
        \\pub fn first() void {
        \\    lib.
        \\}
        \\pub fn second() void {
        \\    deep.
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "lib.zig", .text = "pub fn hello() void {}\n" },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    // The client cannot register file watching dynamically
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("hello", try completionLabels(&h, main_uri, main_text, "    lib."));
    // sub/deep.zig does not exist yet (nor does its directory)
    try testing.expectEqualStrings("", try completionLabels(&h, main_uri, main_text, "    deep."));

    // Rewrite the unopened lib.zig outside the editor, without any notification
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try project.path(a, "lib.zig"), .data = "pub fn goodbye() void {}\n" });
    try waitWatched(&h, Labels{ .uri = main_uri, .text = main_text, .after = "    lib.", .want = "goodbye" });

    // Create a directory and an imported file in it
    try project.tmp.dir.createDirPath(testing.io, "sub");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try project.path(a, "sub/deep.zig"), .data = "pub fn found() void {}\n" });
    try waitWatched(&h, Labels{ .uri = main_uri, .text = main_text, .after = "    deep.", .want = "found" });

    // Create build.zig outside the editor: the project starts; delete it: the project stops
    const build_path = try project.path(a, "build.zig");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = named_module_build });
    try waitWatched(&h, Projects{ .n = 1 });
    try std.Io.Dir.cwd().deleteFile(testing.io, build_path);
    try waitWatched(&h, Projects{ .n = 0 });

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "the server watches files on disk: directories a build creates do not schedule a scan for source files" {
    const main_text = "const lib = @import(\"lib.zig\");\npub fn first() void {\n    lib.\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "lib.zig", .text = "pub fn hello() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    // The client cannot register file watching dynamically
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const lib_path = try project.path(a, "lib.zig");
    // Notifications arrive in order: once this change is noticed, the earlier ones (FSEvents also
    // reports the creation of the fixture's files) have been handled
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = lib_path, .data = "pub fn goodbye() void {}\n" });
    try waitWatched(&h, Labels{ .uri = main_uri, .text = main_text, .after = "    lib.", .want = "goodbye" });
    const scans = h.server.scan_generation.load(.acquire);
    for ([_][]const u8{ "zig-out/bin", ".zig-cache/o/0123", ".zig-cache/tmp" }) |sub| try project.tmp.dir.createDirPath(testing.io, sub);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = lib_path, .data = "pub fn again() void {}\n" });
    try waitWatched(&h, Labels{ .uri = main_uri, .text = main_text, .after = "    lib.", .want = "again" });
    // A scan for them would find nothing new, and find references and rename would wait for it
    try testing.expectEqual(scans, h.server.scan_generation.load(.acquire));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "the server watches files on disk: a change notified under another spelling of a file counts for it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const main_text = "const lib = @import(\"lib.zig\");\npub fn first() void {\n    lib.\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "lib.impl", .text = "pub fn hello() void {}\n" },
    });
    defer project.deinit();
    // The notifications name the file as stored on disk (`lib.impl`), the server knows it as
    // `lib.zig`, as with FSEvents reporting decomposed Unicode names for composed ones
    try project.tmp.dir.symLink(testing.io, "lib.impl", "lib.zig", .{});
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("hello", try completionLabels(&h, main_uri, main_text, "    lib."));
    // Guards against dropping the notification as one for an unknown file
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try project.path(a, "lib.impl"), .data = "pub fn goodbye() void {}\n" });
    try waitWatched(&h, Labels{ .uri = main_uri, .text = main_text, .after = "    lib.", .want = "goodbye" });
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Number of batches of external changes the server has handled
fn watchBatches(h: *Harness) u64 {
    h.server.watch_mutex.lockUncancelable(testing.io);
    defer h.server.watch_mutex.unlock(testing.io);
    return h.server.watch_batches;
}

/// Waits for the server to handle external changes until `cond.done(h)`: checks once each time the
/// server finishes a batch (and is idle). Fails when no new batch arrives within 10 seconds.
fn waitWatched(h: *Harness, cond: anytype) !void {
    var batches = watchBatches(h);
    for (0..50) |_| {
        _ = try h.request("zig-analyzer/waitIdle", {});
        if (try cond.done(h)) return;
        const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
        h.server.watch_mutex.lockUncancelable(testing.io);
        defer h.server.watch_mutex.unlock(testing.io);
        while (h.server.watch_batches == batches) {
            h.server.watch_cond.waitTimeout(testing.io, &h.server.watch_mutex, .{ .deadline = .{ .raw = deadline, .clock = .awake } }) catch return error.ChangeNotNoticed;
        }
        batches = h.server.watch_batches;
    }
    return error.ChangeNotNoticed;
}

/// Condition for `waitWatched`: the completion list after `after` is `want`
const Labels = struct {
    uri: []const u8,
    text: []const u8,
    after: []const u8,
    want: []const u8,

    fn done(c: Labels, h: *Harness) !bool {
        return std.mem.eql(u8, try completionLabels(h, c.uri, c.text, c.after), c.want);
    }
};

/// Condition for `waitWatched`: the project list has `n` projects
const Projects = struct {
    n: usize,

    fn done(c: Projects, h: *Harness) !bool {
        h.server.workspaces_mutex.lockUncancelable(testing.io);
        defer h.server.workspaces_mutex.unlock(testing.io);
        return h.server.workspaces.items.len == c.n;
    }
};

/// Waits for the server to finish another batch of external changes after batch `after`; fails if
/// none arrives within 60 seconds
fn waitBatchAfter(h: *Harness, after: u64) !void {
    const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(60));
    h.server.watch_mutex.lockUncancelable(testing.io);
    defer h.server.watch_mutex.unlock(testing.io);
    while (h.server.watch_batches <= after) {
        h.server.watch_cond.waitTimeout(testing.io, &h.server.watch_mutex, .{ .deadline = .{ .raw = deadline, .clock = .awake } }) catch return error.ChangeNotNoticed;
    }
}

/// Sends waitIdle and reads messages until its response; fails if the server is not idle within
/// `seconds` seconds: while builds keep running waitIdle does not return, and the constant stream
/// of notifications keeps the read of any single message from timing out. Before failing, sends
/// shutdown to stop the projects, so the pending waitIdle returns and the server can exit at the
/// end of the test (before exiting it waits for in-flight requests to finish).
fn waitIdleWithin(h: *Harness, seconds: i64) !void {
    const id = try h.send("zig-analyzer/waitIdle", {});
    const start = std.Io.Clock.awake.now(testing.io);
    var seen: usize = 0;
    while (true) {
        for (h.received.items[seen..]) |msg| {
            if (msg.object.get("method") == null) if (msg.object.get("id")) |i| if (i == .integer and i.integer == id) return;
        }
        seen = h.received.items.len;
        if (start.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds > seconds * std.time.ns_per_s) {
            _ = try h.request("shutdown", {});
            return error.NeverIdle;
        }
        _ = try h.next();
    }
}

/// Number of compiles that finished and replaced their results (project builds and single-file
/// compiles). When something changes during a build, that round's result is discarded and a rebuild
/// starts immediately; it is not counted.
fn compiles(h: *Harness) u64 {
    return h.server.compile_generation.load(.monotonic);
}

/// Number of write transactions of the server
fn writeCount(h: *Harness) !i64 {
    const status = try h.request("zig-analyzer/status", {});
    return status.object.get("result").?.object.get("writes").?.integer;
}

/// Number of times diagnostics were published for `uri`
fn publishCount(h: *Harness, uri: []const u8) !usize {
    var n: usize = 0;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        if (std.mem.eql(u8, m.object.get("params").?.object.get("uri").?.string, uri)) n += 1;
    }
    return n;
}

test "rewriting files on disk without changing their content is not a change" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } } });
    try h.notify("initialized", Empty{});
    try open(&h, try za.base.uri.fromPath(a, try project.path(a, "src/main.zig")), fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const lib_path = try project.path(a, "src/lib.zig");
    const lib_uri = try za.base.uri.fromPath(a, lib_path);
    const builds = compiles(&h);
    const writes = try writeCount(&h);
    const published = try publishCount(&h, lib_uri);
    try testing.expect(builds > 0);
    try testing.expect(published > 0);

    // Rewrite with the same content (generated code written by a build step): the known text is
    // unchanged, so nothing is written. The server does not know whether the last build read this
    // content on disk, so it rebuilds once.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = lib_path, .data = fixture.basic[2].text });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = lib_uri, .type = 2 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(builds + 1, compiles(&h));
    try testing.expectEqual(writes, try writeCount(&h));

    // Rewrite with the same content again, plus an atomic save that deletes the file and then
    // creates it again: no write, no rebuild, no republish
    const rebuilt = compiles(&h);
    const republished = try publishCount(&h, lib_uri);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = lib_path, .data = fixture.basic[2].text });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = lib_uri, .type = 2 }} });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{ .{ .uri = lib_uri, .type = 3 }, .{ .uri = lib_uri, .type = 1 } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(rebuilt, compiles(&h));
    try testing.expectEqual(writes, try writeCount(&h));
    try testing.expectEqual(republished, try publishCount(&h, lib_uri));

    // The content really changes: written and rebuilt, and the compiler diagnostics of lib.zig are
    // cleared along with it
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = lib_path, .data = "pub fn hello() void {}\n" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = lib_uri, .type = 2 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(compiles(&h) > rebuilt);
    try testing.expect(try writeCount(&h) > writes);
    try testing.expectEqual(@as(usize, 0), (try lastDiagnostics(&h, lib_uri)).?.len);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a build step that rewrites a source file with the same content does not rebuild in a loop" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const gen = b.addExecutable(.{ .name = "gen", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("tools/gen.zig"),
        \\        .target = b.graph.host,
        \\    }) });
        \\    // A run step with no declared outputs runs on every build: it rewrites src/gen.zig in the source tree verbatim
        \\    const run = b.addRunArtifact(gen);
        \\    run.addDirectoryArg(b.path("src"));
        \\    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = b.standardTargetOptions(.{}),
        \\        .optimize = b.standardOptimizeOption(.{}),
        \\    }) });
        \\    exe.step.dependOn(&run.step);
        \\    b.installArtifact(exe);
        \\    const check = b.step("check", "Check that everything compiles");
        \\    check.dependOn(&exe.step);
        \\}
        \\
        },
        .{ .path = "tools/gen.zig", .text =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {
        \\    var args = try init.minimal.args.iterateAllocator(init.gpa);
        \\    defer args.deinit();
        \\    _ = args.next();
        \\    const path = try std.fs.path.join(init.gpa, &.{ args.next().?, "gen.zig" });
        \\    defer init.gpa.free(path);
        \\    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = "pub const value = 1;\n" });
        \\}
        \\
        },
        .{ .path = "src/main.zig", .text = "const gen = @import(\"gen.zig\");\npub fn main() void {\n    _ = gen.value;\n}\n" },
        .{ .path = "src/gen.zig", .text = "pub const value = 1;\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    // The client cannot register file watching dynamically: the server watches, so writes by the
    // generate step are noticed
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, "const gen = @import(\"gen.zig\");\npub fn main() void {\n    _ = gen.value;\n}\n");
    // Treating the rewrite as a change would build again and rewrite again, never becoming idle
    // (which happens if watching is already ready at the first build)
    try waitIdleWithin(&h, 120);
    _ = try h.request("zig-analyzer/waitIdle", {});

    // A save triggers one build: the generate step rewrites src/gen.zig with the same content. The
    // first time the server notices it, it does not know whether the last build read this content,
    // so it may build once more (not if it already noticed it during startup); later notices no
    // longer trigger a build.
    for (0..2) |round| {
        const builds = compiles(&h);
        const batches = watchBatches(&h);
        try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
        try waitBatchAfter(&h, batches);
        try waitIdleWithin(&h, 60);
        _ = try h.request("zig-analyzer/waitIdle", {});
        const n = compiles(&h) - builds;
        if (round == 0) try testing.expect(n == 1 or n == 2) else try testing.expectEqual(1, n);
    }

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "workspace folders: added folders start a project, removed ones clear its diagnostics" {
    var first = try fixture.Project.create(&.{.{ .path = "a.zig", .text = "pub const a = 1;\n" }});
    defer first.deinit();
    var second = try fixture.Project.create(&fixture.basic);
    defer second.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const first_uri = try za.base.uri.fromPath(a, first.root);
    const second_uri = try za.base.uri.fromPath(a, second.root);
    const init = try h.request("initialize", .{ .workspaceFolders = &.{.{ .uri = first_uri, .name = "first" }}, .capabilities = Empty{} });
    const folders = init.object.get("result").?.object.get("capabilities").?.object.get("workspace").?.object.get("workspaceFolders").?.object;
    try testing.expect(folders.get("changeNotifications").?.bool);
    try h.notify("initialized", Empty{});
    _ = try h.request("zig-analyzer/waitIdle", {});

    // Add a folder with build.zig: builds and publishes compiler diagnostics (main.zig is not open)
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &.{.{ .uri = second_uri, .name = "second" }}, .removed = &[_]Empty{} } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const main_uri = try za.base.uri.fromPath(a, try second.path(a, "src/main.zig"));
    const before = (try lastDiagnostics(&h, main_uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, before.len);
    try testing.expect(std.mem.indexOf(u8, before[0], "expected type 'u32'") != null);

    // Remove it: the project stops and the diagnostics are cleared
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &[_]Empty{}, .removed = &.{.{ .uri = second_uri, .name = "second" }} } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, (try lastDiagnostics(&h, main_uri)).?.len);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a project is not started for a folder removed before its start" {
    // Guards against startup, which iterates a copy of the root directories, starting (and keeping
    // loaded) the project of a folder that the client removed meanwhile
    var first = try fixture.Project.create(&.{.{ .path = "a.zig", .text = "pub const a = 1;\n" }});
    defer first.deinit();
    var second = try fixture.Project.create(&fixture.basic);
    defer second.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const first_uri = try za.base.uri.fromPath(a, first.root);
    const second_uri = try za.base.uri.fromPath(a, second.root);
    _ = try h.request("initialize", .{ .workspaceFolders = &.{ .{ .uri = first_uri, .name = "first" }, .{ .uri = second_uri, .name = "second" } }, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(try (Projects{ .n = 1 }).done(&h));
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &[_]Empty{}, .removed = &.{.{ .uri = second_uri, .name = "second" }} } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(try (Projects{ .n = 0 }).done(&h));

    // The start that startup began for the folder before the removal comes in after it
    h.server.startWorkspace(second.root);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(try (Projects{ .n = 0 }).done(&h));

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "removed workspace folder: open files belong to a project that is not loaded, with a hint" {
    const main_text =
        \\pub fn main() void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\}
        \\
    ;
    const build_zig =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.graph.host,
        \\    }) });
        \\    b.installArtifact(exe);
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = build_zig },
        .{ .path = "main.zig", .text = main_text },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_path = try project.path(a, "main.zig");
    const main_uri = try za.base.uri.fromPath(a, main_path);
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const before = (try lastDiagnostics(&h, main_uri)) orelse return error.NoDiagnostics;
    try testing.expect(std.mem.indexOf(u8, before[0], "expected type 'u32'") != null);

    // Remove the root directory: the directory still contains build.zig, so the open file belongs
    // to a project that is not loaded. The project's compiler diagnostics are cleared, the file is
    // not compiled on its own, and only a hint remains.
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &[_]Empty{}, .removed = &.{.{ .uri = root_uri, .name = "p" }} } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const after = (try lastDiagnostics(&h, main_uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, after.len);
    try testing.expect(std.mem.startsWith(u8, after[0], "this file belongs to the project at"));
    h.server.single_mutex.lockUncancelable(testing.io);
    const single_count = h.server.single.count();
    h.server.single_mutex.unlock(testing.io);
    try testing.expectEqual(0, single_count);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "untitled documents: diagnostics and hover use the original URI" {
    var project = try fixture.Project.create(&.{.{ .path = "a.zig", .text = "pub const a = 1;\n" }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-1";
    const text = "fn f() void {\n    const y: u8 = 1;\n}\n";
    try open(&h, uri, text);
    _ = try h.request("zig-analyzer/waitIdle", {});

    const diags = (try lastDiagnostics(&h, uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0], "unused local constant") != null);

    const p = position(text, "const ");
    const hover = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = p });
    const contents = hover.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, contents, "const y: u8") != null);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "completion of @import paths lists modules, files and directories" {
    const main_text = "const a = @import(\"\");\nconst b = @import(\"sub/\");\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "util.zig", .text = "" },
        .{ .path = "notes.txt", .text = "" },
        .{ .path = "sub/inner.zig", .text = "" },
        .{ .path = "sub/data.zon", .text = ".{}" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});

    const cases = [_]struct { []const u8, []const u8, u32 }{
        .{ "a = @import(\"", "builtin main.zig root std sub/ util.zig", 19 },
        .{ "b = @import(\"sub/", "sub/data.zon sub/inner.zig", 19 },
    };
    for (cases) |c| {
        const resp = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = position(main_text, c[0]) });
        var labels: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |item| {
            try labels.append(a, item.object.get("label").?.string);
            // The replacement range starts at the beginning of the string content
            const start = item.object.get("textEdit").?.object.get("range").?.object.get("start").?.object;
            try testing.expectEqual(c[2], start.get("character").?.integer);
        }
        std.mem.sort([]const u8, labels.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        try testing.expectEqualStrings(c[1], try std.mem.join(a, " ", labels.items));
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "live diagnostics in a library whose default step compiles nothing" {
    // Only addModule and addTest: the default install step is empty, so the compile set uses all
    // compile steps in the build graph instead
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const mod = b.addModule("lib", .{ .root_source_file = b.path("lib.zig"), .target = b.graph.host });
        \\    const tests = b.addTest(.{ .root_module = mod });
        \\    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        },
        .{ .path = "lib.zig", .text = "pub const a = 1;\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "lib.zig"));
    try open(&h, uri, "pub const a = 1;\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = &.{.{ .text = "pub const a = 1;\n@@\n" }} });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const diags = (try lastDiagnostics(&h, uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0], "invalid token") != null);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "files reachable only from non-default steps resolve module imports" {
    // The default install compiles only app; t.zig is only in the test step's module, through which
    // it imports module lib
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const lib = b.addModule("lib", .{ .root_source_file = b.path("lib.zig"), .target = b.graph.host });
        \\    const app = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("app.zig"), .target = b.graph.host }) });
        \\    b.installArtifact(app);
        \\    const tests = b.addTest(.{ .root_module = b.createModule(.{
        \\        .root_source_file = b.path("t.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "lib", .module = lib }},
        \\    }) });
        \\    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        },
        .{ .path = "app.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "lib.zig", .text = "pub fn answer() u32 {\n    return 42;\n}\n" },
        .{ .path = "t.zig", .text = "const lib = @import(\"lib\");\ntest {\n    _ = lib.answer();\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const text = "const lib = @import(\"lib\");\ntest {\n    _ = lib.answer();\n}\n";
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "t.zig"));
    try open(&h, uri, text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("answer", try completionLabels(&h, uri, text, "lib."));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "files of a package that only exports modules resolve module imports" {
    // No compile step in the build graph: lib is compiled only by its users, and module membership
    // comes from the exported modules
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const dep = b.createModule(.{ .root_source_file = b.path("dep.zig") });
        \\    _ = b.addModule("lib", .{ .root_source_file = b.path("lib.zig"), .imports = &.{.{ .name = "dep", .module = dep }} });
        \\}
        \\
        },
        .{ .path = "dep.zig", .text = "pub fn answer() u32 {\n    return 42;\n}\n" },
        .{ .path = "lib.zig", .text = "const dep = @import(\"dep\");\npub fn f() void {\n    _ = dep.answer();\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const text = "const dep = @import(\"dep\");\npub fn f() void {\n    _ = dep.answer();\n}\n";
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "lib.zig"));
    try open(&h, uri, text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("answer", try completionLabels(&h, uri, text, "dep."));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Modules the file belongs to (from `zig-analyzer/fileStatus`), as their root file paths; empty
/// when the server does not know the file
fn fileModules(h: *Harness, uri: []const u8) ![]const []const u8 {
    const result = (try h.request("zig-analyzer/fileStatus", .{ .textDocument = .{ .uri = uri } })).object.get("result").?;
    if (result == .null) return &.{};
    const status = result.object;
    var modules: std.ArrayList([]const u8) = .empty;
    for (status.get("modules").?.array.items) |m| try modules.append(h.arena.allocator(), m.string);
    return modules.items;
}

test "files imported only through a file with a syntax error keep their module membership" {
    // A build that completes while main.zig does not parse must not drop core.zig and util.zig
    // from their modules: `zig build` passes the same module arguments either way
    const core_text = "const util = @import(\"util\");\npub fn run() u32 {\n    return util.answer;\n}\n";
    const main_text = "const core = @import(\"core\");\npub fn main() void {\n    _ = core.run();\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const util = b.createModule(.{ .root_source_file = b.path("lib/util.zig"), .target = b.graph.host });
        \\    const core = b.createModule(.{ .root_source_file = b.path("lib/core.zig"), .target = b.graph.host, .imports = &.{.{ .name = "util", .module = util }} });
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host, .imports = &.{.{ .name = "core", .module = core }} }) });
        \\    b.step("check", "Check").dependOn(&exe.step);
        \\}
        \\
        },
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "lib/core.zig", .text = core_text },
        .{ .path = "lib/util.zig", .text = "pub const answer: u32 = 42;\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    const core_uri = try za.base.uri.fromPath(a, try project.path(a, "lib/core.zig"));
    const util_uri = try za.base.uri.fromPath(a, try project.path(a, "lib/util.zig"));
    try open(&h, main_uri, main_text);
    try open(&h, core_uri, core_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("answer", try completionLabels(&h, core_uri, core_text, "util."));

    // Saved with a parse error: the build completes and the compile set is recomputed
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 2 }, .contentChanges = &.{.{ .text = "const core = @import(\"core\");\npub fn main() void {\n    _ = core.run();\n    const y = 1\n}\n" }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("answer", try completionLabels(&h, core_uri, core_text, "util."));
    try testing.expectEqual(1, (try fileModules(&h, util_uri)).len);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a new @import adds the file to the compile set without a build" {
    // With compiler diagnostics off no build ever runs: the edit alone must bring b.zig into
    // main.zig's module, so references and rename of `a.Point` include the closed b.zig
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host }) });
        \\    b.step("check", "Check").dependOn(&exe.step);
        \\}
        \\
        },
        .{ .path = "src/a.zig", .text = "pub const Point = struct { x: u32 };\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub fn getX(p: a.Point) u32 {\n    return p.x;\n}\n" },
        .{ .path = "src/main.zig", .text = "const a = @import(\"a.zig\");\npub fn main() void {\n    const p: a.Point = .{ .x = 1 };\n    _ = p;\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    const options = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"diagnostics\": {\"compiler\": false}}", .{});
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = options });
    try h.notify("initialized", Empty{});
    const main_path = try project.path(a, "src/main.zig");
    const main_uri = try za.base.uri.fromPath(a, main_path);
    const a_uri = try za.base.uri.fromPath(a, try project.path(a, "src/a.zig"));
    const b_uri = try za.base.uri.fromPath(a, try project.path(a, "src/b.zig"));
    try open(&h, main_uri, "const a = @import(\"a.zig\");\npub fn main() void {\n    const p: a.Point = .{ .x = 1 };\n    _ = p;\n}\n");
    _ = try h.request("zig-analyzer/waitIdle", {});

    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 2 }, .contentChanges = &.{.{ .text = "const a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\npub fn main() void {\n    const p: a.Point = .{ .x = 1 };\n    _ = b.getX(p);\n}\n" }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const modules = try fileModules(&h, b_uri);
    try testing.expectEqual(1, modules.len);
    try testing.expectEqualStrings(main_path, modules[0]);
    const refs = (try h.request("textDocument/references", .{ .textDocument = .{ .uri = a_uri }, .position = .{ .line = 0, .character = 10 }, .context = .{ .includeDeclaration = true } })).object.get("result").?.array.items;
    var in_b: usize = 0;
    for (refs) |r| {
        if (std.mem.eql(u8, r.object.get("uri").?.string, b_uri)) in_b += 1;
    }
    try testing.expectEqual(1, in_b);
    try testing.expectEqual(3, refs.len);

    // The newly imported file gets live diagnostics
    try open(&h, b_uri, "const a = @import(\"a.zig\");\npub fn getX(p: a.Point) u32 {\n    return p.x +;\n}\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    const diags = (try lastDiagnostics(&h, b_uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0], "whitespace") != null);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "live diagnostics for files of module directories outside the diagnostics compile set" {
    // util.zig is imported nowhere yet and parser_test.zig is compiled only by the test step: both
    // must still get their syntax and AstGen errors. tools/gen.zig is outside every module
    // directory, can never be compiled with the project, and gets none.
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host }) });
        \\    b.step("check", "Check").dependOn(&exe.step);
        \\    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/root.zig"), .target = b.graph.host }) });
        \\    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "test/root.zig", .text = "test {\n    _ = @import(\"parser_test.zig\");\n}\n" },
        .{ .path = "test/parser_test.zig", .text = "test \"parse\" {}\n" },
        .{ .path = "tools/gen.zig", .text = "pub fn main() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    _ = try h.request("zig-analyzer/waitIdle", {});
    try open(&h, try za.base.uri.fromPath(a, try project.path(a, "src/util.zig")), "pub fn add(a: u32, b: u32) u32 {\n    return a + ;\n}\n");
    try open(&h, try za.base.uri.fromPath(a, try project.path(a, "test/parser_test.zig")), "const std = @import(\"std\");\ntest \"parse\" {\n    const unused = 1;\n    try std.testing.expect(true);\n}\n");
    try open(&h, try za.base.uri.fromPath(a, try project.path(a, "tools/gen.zig")), "pub fn main() void {\n    const unused = 1;\n}\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    const diags = try h.diagnostics();
    const util = diags.get("util.zig").?;
    try testing.expectEqual(1, util.len);
    try testing.expect(std.mem.startsWith(u8, util[0], "1:15 ") and std.mem.endsWith(u8, util[0], "expected expression, found ';'"));
    const parser_test = diags.get("parser_test.zig").?;
    try testing.expectEqual(1, parser_test.len);
    try testing.expect(std.mem.startsWith(u8, parser_test[0], "2:10 ") and std.mem.endsWith(u8, parser_test[0], "unused local constant"));
    try testing.expectEqual(0, diags.get("gen.zig").?.len);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a project whose background task cannot be started does not leave the server busy" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    // Concurrent tasks are not allowed: the project's background task fails to start
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: za.lsp.transport.Writer = .{ .io = testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(threaded.io(), testing.allocator, &writer);
    defer server.deinit();
    server.zig_env = try server.ownEnv(try za.project.ZigEnv.query(testing.allocator, testing.io, project.env.zig_exe));

    try testing.expectError(error.ConcurrencyUnavailable, Workspace.start(&server, project.root, 0));
    const busy = server.busy;
    // If the count leaks, waitIdle in deinit waits forever: reset it to zero first so the failing
    // test ends normally
    server.busy = 0;
    try testing.expectEqual(0, busy);
}

/// Waits until the message of some progress report contains `needle`
fn waitProgress(h: *Harness, needle: []const u8) !void {
    while (true) {
        const msg = try h.next();
        const method = msg.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "$/progress")) continue;
        const value = msg.object.get("params").?.object.get("value").?.object;
        const text = value.get("message") orelse value.get("title") orelse continue;
        if (text == .string and std.mem.indexOf(u8, text.string, needle) != null) return;
    }
}

/// Waits until the server sends a `method` request (answered by `Harness.next`)
fn waitRequest(h: *Harness, method: []const u8) !void {
    while (true) {
        const msg = try h.next();
        if (msg.object.get("id") == null) continue;
        const m = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, m.string, method)) return;
    }
}

/// Process group of the project's current maker
fn makerGroup(h: *Harness) std.posix.pid_t {
    h.server.workspaces_mutex.lockUncancelable(testing.io);
    defer h.server.workspaces_mutex.unlock(testing.io);
    const ws = h.server.workspaces.items[0];
    ws.mutex.lockUncancelable(testing.io);
    defer ws.mutex.unlock(testing.io);
    return ws.client.?.group.pgid;
}

test "shutdown during a build ends zig build and its child processes without waiting for the build" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.slow);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .window = .{ .workDoneProgress = true } } });
    try h.notify("initialized", Empty{});
    // The build reaches the 60-second sleep: the maker reads the next message only after the build
    // ends
    try waitProgress(&h, "run sleep");
    const pgid = makerGroup(&h);

    const t0 = std.Io.Clock.awake.now(testing.io);
    _ = try h.request("shutdown", {});
    const elapsed = t0.durationTo(std.Io.Clock.awake.now(testing.io));
    try testing.expect(elapsed.toSeconds() < 10);
    try fixture.expectGroupGone(pgid);
    try h.notify("exit", {});
}

/// Process id of the project's current maker
fn makerPid(h: *Harness) std.posix.pid_t {
    h.server.workspaces_mutex.lockUncancelable(testing.io);
    defer h.server.workspaces_mutex.unlock(testing.io);
    const ws = h.server.workspaces.items[0];
    ws.mutex.lockUncancelable(testing.io);
    defer ws.mutex.unlock(testing.io);
    return ws.client.?.child.id.?;
}

/// After the `from`-th diagnostics notification, diagnostics were published for `uri` at least
/// once, and each publish contains `needle`
fn expectEveryPublishContains(h: *Harness, from: usize, uri: []const u8, needle: []const u8) !void {
    var count: usize = 0;
    for ((try h.notifications("textDocument/publishDiagnostics"))[from..]) |m| {
        const params = m.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
        count += 1;
        const found = for (params.get("diagnostics").?.array.items) |d| {
            if (std.mem.indexOf(u8, d.object.get("message").?.string, needle) != null) break true;
        } else false;
        if (!found) {
            std.debug.print("publish #{d} of {s} lacks \"{s}\"\n", .{ count, uri, needle });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(count >= 1);
}

/// Replaced instances are freed after their background tasks end: the number of live instances
/// returns to `expected` within a few seconds
fn expectLiveWorkspaces(h: *Harness, expected: usize) !void {
    for (0..100) |_| {
        if (h.server.live_workspaces.load(.monotonic) == expected) return;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }
    try testing.expectEqual(expected, h.server.live_workspaces.load(.monotonic));
}

test "restarting a project keeps the previous compiler diagnostics until the new instance has built" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .window = .{ .workDoneProgress = true } } });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const before = (try lastDiagnostics(&h, main_uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, before.len);
    try testing.expect(std.mem.indexOf(u8, before[0], "expected type 'u32'") != null);

    // Save build.zig: restart with a new instance. Until the new instance's first build finishes,
    // open files must not lose their compiler diagnostics.
    var from = (try h.notifications("textDocument/publishDiagnostics")).len;
    const build_uri = try za.base.uri.fromPath(a, try project.path(a, "build.zig"));
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try expectEveryPublishContains(&h, from, main_uri, "expected type 'u32'");

    // The maker crashes: restarts automatically, and the diagnostics are kept as well. Waits for
    // idle only after the new instance has requested a progress token (before that, the server may
    // not have noticed the crash yet).
    if (@import("builtin").os.tag != .windows) {
        from = (try h.notifications("textDocument/publishDiagnostics")).len;
        try std.posix.kill(makerPid(&h), .KILL);
        try waitRequest(&h, "window/workDoneProgress/create");
        _ = try h.request("zig-analyzer/waitIdle", {});
        try expectEveryPublishContains(&h, from, main_uri, "expected type 'u32'");
    }

    // All replaced instances have been freed
    try expectLiveWorkspaces(&h, 1);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "restarting a project during a build stops the old build system first" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.slow);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .window = .{ .workDoneProgress = true } } });
    try h.notify("initialized", Empty{});
    try waitProgress(&h, "run sleep");
    const old = makerGroup(&h);

    // Save build.zig during a build: the old build ends immediately and does not run alongside the
    // new instance's build
    const build_uri = try za.base.uri.fromPath(a, try project.path(a, "build.zig"));
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    try fixture.expectGroupGone(old);
    try waitProgress(&h, "run sleep");
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Whether the last diagnostics published for `uri` include one containing `needle`
fn lastHas(h: *Harness, uri: []const u8, needle: []const u8) !bool {
    const diags = (try lastDiagnostics(h, uri)) orelse return false;
    for (diags) |d| if (std.mem.indexOf(u8, d, needle) != null) return true;
    return false;
}

/// The only instance in the project list
fn visibleInstance(h: *Harness) *Workspace {
    h.server.workspaces_mutex.lockUncancelable(testing.io);
    defer h.server.workspaces_mutex.unlock(testing.io);
    return h.server.workspaces.items[0];
}

/// File name of the goto result ("null" without a result; "error" when a write transaction ordered
/// after the request answers it with ContentModified)
fn gotoFile(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    const resp = try h.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = position(text, needle) });
    const result = resp.object.get("result") orelse return "error";
    if (result == .null) return "null";
    const target = result.object.get("uri").?.string;
    return target[std.mem.lastIndexOfScalar(u8, target, '/').? + 1 ..];
}

test "fixing a build.zig that failed to compile: named modules resolve once the build graph is read, before the build ends" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // The build runs an external command for 60 seconds: the build does not end during the test
    const fixed =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const geo = b.createModule(.{ .root_source_file = b.path("geo.zig") });
        \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "geo", .module = geo }},
        \\    }) });
        \\    const check = b.step("check", "Check");
        \\    check.dependOn(&exe.step);
        \\    check.dependOn(&b.addSystemCommand(&.{ "sleep", "60" }).step);
        \\}
        \\
    ;
    const main_text = "const geo = @import(\"geo\");\npub fn main() void {\n    _ = geo.name;\n}\n";
    const broken = try std.mem.replaceOwned(u8, testing.allocator, fixed, "b.graph.host", "b.graph.hots");
    defer testing.allocator.free(broken);
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = broken },
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const build_path = try project.path(a, "build.zig");
    const build_uri = try za.base.uri.fromPath(a, build_path);
    try testing.expect(try lastHas(&h, build_uri, "hots"));
    try testing.expectEqualStrings("null", try gotoFile(&h, main_uri, main_text, "geo.na"));

    // Fix and save: the old instance has no build graph to keep using, so the new instance replaces
    // it as soon as it has read the build graph, without waiting for the build to end
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = fixed });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    for (0..400) |_| {
        if (std.mem.eql(u8, try gotoFile(&h, main_uri, main_text, "geo.na"), "geo.zig")) break;
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    } else return error.TestUnexpectedResult;
    // The compile errors of build.zig are cleared along with the old instance
    for (0..100) |_| {
        if (!try lastHas(&h, build_uri, "hots")) break;
        _ = try h.request("zig-analyzer/status", {});
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    } else return error.TestUnexpectedResult;
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "abandoning a restart clears the previous compiler diagnostics and keeps the build graph" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    // Wrap the user's zig: while the hang file exists, `zig build` sends nothing. `zig env` reports
    // the wrapper script itself as zig.
    const zig = project.env.zig_exe;
    const script = try std.fmt.allocPrint(testing.allocator,
        \\#!/bin/sh
        \\case "$1" in
        \\env) "{s}" env | sed 's|\.zig_exe = "[^"]*"|.zig_exe = "{s}/zigw"|' ;;
        \\build) if [ -e "{s}/hang" ]; then exec sleep 600; fi; exec "{s}" "$@" ;;
        \\*) exec "{s}" "$@" ;;
        \\esac
        \\
    , .{ zig, project.root, project.root, zig, zig });
    defer testing.allocator.free(script);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    const options = try std.fmt.allocPrint(a, "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{project.root});
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = try std.json.parseFromSliceLeaky(std.json.Value, a, options, .{}) });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));

    // Save build.zig: the new instance never gets a result and is then abandoned (as when the maker
    // keeps crashing)
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "hang", .data = "" });
    const build_uri = try za.base.uri.fromPath(a, try project.path(a, "build.zig"));
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    const ws = visibleInstance(&h);
    const pending = for (0..100) |_| {
        h.server.workspaces_mutex.lockUncancelable(testing.io);
        const s = ws.successor;
        if (s) |p| p.acquire();
        h.server.workspaces_mutex.unlock(testing.io);
        if (s) |p| break p;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    } else return error.TestUnexpectedResult;
    pending.stop();
    h.server.abandon(pending);
    pending.release();
    _ = try h.request("zig-analyzer/waitIdle", {});
    // The old compiler diagnostics are no longer updated: they are no longer shown; the old
    // instance's build graph is still used for module membership
    try testing.expect(!try lastHas(&h, main_uri, "expected type 'u32'"));
    try testing.expect(visibleInstance(&h) == ws);
    try testing.expect(ws.successor == null);
    try testing.expect(ws.inModuleGraph());

    // Save build.zig again: starts over
    try project.tmp.dir.deleteFile(testing.io, "hang");
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a restart or build requested through a replaced instance applies to the project's current instance" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    // An instance from a snapshot of the list held by a caller
    const stale = visibleInstance(&h);
    stale.acquire();
    defer stale.release();
    const build_uri = try za.base.uri.fromPath(a, try project.path(a, "build.zig"));
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const current = visibleInstance(&h);
    try testing.expect(current != stale);

    // The build request is forwarded to the current instance: files with compiler diagnostics are
    // republished
    const before = (try h.notifications("textDocument/publishDiagnostics")).len;
    h.server.requestBuild(stale);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect((try h.notifications("textDocument/publishDiagnostics")).len > before);

    // Restart the current instance
    h.server.restartWorkspace(stale, 0);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(visibleInstance(&h) != current);
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a new instance handles build events only after the server has placed it" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    // No workspace folders: the test starts the project. The compiler is not run, so there are no
    // builds after configuration is done.
    const options = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"diagnostics\": {\"compiler\": false}}", .{});
    _ = try h.request("initialize", .{ .capabilities = Empty{}, .initializationOptions = options });
    try h.notify("initialized", Empty{});
    const main_path = try project.path(a, "src/main.zig");
    const main_uri = try za.base.uri.fromPath(a, main_path);
    try open(&h, main_uri, fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});

    const ws = try Workspace.start(&h.server, project.root, 0);
    // No events are handled before the instance is added to the list: by then the maker has long
    // since sent the build graph
    var handled = false;
    for (0..30) |_| {
        ws.mutex.lockUncancelable(testing.io);
        handled = ws.model != null;
        ws.mutex.unlock(testing.io);
        if (handled) break;
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    }
    {
        h.server.workspaces_mutex.lockUncancelable(testing.io);
        defer h.server.workspaces_mutex.unlock(testing.io);
        try h.server.workspaces.append(testing.allocator, ws);
        ws.placed.set(testing.io);
    }
    try testing.expect(!handled);
    // Once added to the list, the build graph it reads goes into the module graph
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("lib.zig", try gotoFile(&h, main_uri, fixture.basic[1].text, "lib.hel"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Source file that uses only the named module geo; without build.zig it is compiled as a single
/// file and the module is not found
const named_module_main = "const geo = @import(\"geo\");\npub fn main() void {\n    const x: u32 = geo.name;\n    _ = x;\n}\n";
const named_module_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const geo = b.createModule(.{ .root_source_file = b.path("geo.zig") });
    \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "geo", .module = geo }},
    \\    }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;

test "a build.zig reported created and then saved: the project restarted during loading still publishes compiler diagnostics" {
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = named_module_main },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = .{ .files = .{ .watcher = "client" } } });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, named_module_main);
    _ = try h.request("zig-analyzer/waitIdle", {});

    const build_path = try project.path(a, "build.zig");
    const build_uri = try za.base.uri.fromPath(a, build_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = named_module_build });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = build_uri, .type = 1 }} });
    try open(&h, build_uri, named_module_build);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "creating or deleting build.zig in a workspace folder starts or stops its project" {
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = named_module_main },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, named_module_main);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "no module named 'geo'"));

    // Create build.zig outside the editor (as zig init does): the project starts and the named
    // module resolves
    const build_path = try project.path(a, "build.zig");
    const build_uri = try za.base.uri.fromPath(a, build_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = named_module_build });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = build_uri, .type = 1 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));
    try testing.expect(!try lastHas(&h, main_uri, "no module named"));

    // Delete it: the project stops and the open file is compiled as a single file again
    try std.Io.Dir.cwd().deleteFile(testing.io, build_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = build_uri, .type = 3 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "no module named 'geo'"));

    // Create and save build.zig in the editor (no file watching): the project starts as well
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = named_module_build });
    try open(&h, build_uri, named_module_build);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));

    // Delete build.zig while build system integration is off (no event), then turn it back on:
    // rechecked against the disk, and no project starts
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .build = .{ .enable = false } } } });
    try std.Io.Dir.cwd().deleteFile(testing.io, build_path);
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .build = .{ .enable = true } } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, h.server.workspaces.items.len);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Hover text at `line:character` in `uri`
fn hoverText(h: *Harness, uri: []const u8, line: u32, character: u32) ![]const u8 {
    const resp = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } });
    const result = resp.object.get("result") orelse return "";
    if (result != .object) return "";
    return result.object.get("contents").?.object.get("value").?.string;
}

/// Condition for `waitWatched`: the hover text contains `want`
const Hover = struct {
    uri: []const u8,
    line: u32,
    character: u32,
    want: []const u8,

    fn done(c: Hover, h: *Harness) !bool {
        return std.mem.indexOf(u8, try hoverText(h, c.uri, c.line, c.character), c.want) != null;
    }
};

test "files read by @embedFile are watched on disk by the server, or registered with the client" {
    const main_text = "const greeting = @embedFile(\"greeting.txt\");\n";
    inline for (.{ false, true }) |client_watches| {
        var project = try fixture.Project.create(&.{
            .{ .path = "main.zig", .text = main_text },
            .{ .path = "greeting.txt", .text = "hi" },
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
        const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
        try open(&h, main_uri, main_text);
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expectEqualStrings(
            "```zig\nconst greeting: *const [2:0]u8 = @embedFile(\"greeting.txt\")\n```\n\nEmbedded file `greeting.txt`: 2 bytes\n\n```text\nhi\n```",
            try hoverText(&h, main_uri, 0, 7),
        );

        const path = try project.path(a, "greeting.txt");
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "hello" });
        if (client_watches) {
            // The client registered it by file name (sent by a background task after the file is
            // interned)
            var registered = false;
            while (!registered) {
                for (h.received.items) |m| {
                    const method = m.object.get("method") orelse continue;
                    if (!std.mem.eql(u8, method.string, "client/registerCapability")) continue;
                    for (m.object.get("params").?.object.get("registrations").?.array.items) |r| {
                        const options = r.object.get("registerOptions") orelse continue;
                        for (options.object.get("watchers").?.array.items) |watcher| {
                            if (std.mem.eql(u8, watcher.object.get("globPattern").?.string, "**/greeting.txt")) registered = true;
                        }
                    }
                }
                if (!registered) _ = try h.next();
            }
            try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = try za.base.uri.fromPath(a, path), .type = 2 }} });
            _ = try h.request("zig-analyzer/waitIdle", {});
            try testing.expect(std.mem.indexOf(u8, try hoverText(&h, main_uri, 0, 7), "```text\nhello\n```") != null);
        } else {
            try waitWatched(&h, Hover{ .uri = main_uri, .line = 0, .character = 7, .want = "```text\nhello\n```" });
        }
    }
}

/// Condition for `waitWatched`: the last diagnostics published for `uri` include one containing
/// `needle` (`has`), or none does (`!has`)
const Diagnostic = struct {
    uri: []const u8,
    needle: []const u8,
    has: bool,

    fn done(c: Diagnostic, h: *Harness) !bool {
        return try lastHas(h, c.uri, c.needle) == c.has;
    }
};

const check_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.installArtifact(exe);
    \\    const check = b.step("check", "Check");
    \\    check.dependOn(&exe.step);
    \\}
    \\
;

// Prevents ignoring an open document rewritten on disk: the build reads the disk, so keeping the
// old build's diagnostics would map them onto the new text
test "an open document rewritten on disk is rebuilt, with the client's or the server's watcher" {
    const v1 = "const T = u8;\nconst util = @import(\"util.zig\");\npub fn main() void {\n    const bad: T = 300;\n    _ = bad;\n    util.f();\n}\n";
    const v2 = "const T = u16;\nconst util = @import(\"util.zig\");\npub fn main() void {\n    const bad: T = 300;\n    _ = bad;\n    util.f();\n}\n";
    const v3 = "const T = u8;\nconst util = @import(\"util.zig\");\npub fn main() void {\n    const bad: T = 300;\n    _ = bad;\n    util.f();\n}\n// saved\n";
    const message = "type 'u8' cannot represent integer value '300'";
    inline for (.{ "client", "server" }) |watcher| {
        const client = comptime std.mem.eql(u8, watcher, "client");
        var project = try fixture.Project.create(&.{
            .{ .path = "build.zig", .text = check_build },
            .{ .path = "src/main.zig", .text = v1 },
            .{ .path = "src/util.zig", .text = "pub fn f() void {}\n" },
        });
        defer project.deinit();
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        const a = h.arena.allocator();
        const root_uri = try za.base.uri.fromPath(a, project.root);
        _ = try h.request("initialize", .{
            .rootUri = root_uri,
            .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } },
            .initializationOptions = .{ .files = .{ .watcher = watcher } },
        });
        try h.notify("initialized", Empty{});
        const main_path = try project.path(a, "src/main.zig");
        const main_uri = try za.base.uri.fromPath(a, main_path);
        try open(&h, main_uri, v1);
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expect(try lastHas(&h, main_uri, message));

        // Rewritten on disk (git checkout), and the editor reloads the buffer without saving
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = main_path, .data = v2 });
        if (client) try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = main_uri, .type = 2 }} });
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 2 }, .contentChanges = &.{.{ .text = v2 }} });
        try waitWatched(&h, Diagnostic{ .uri = main_uri, .needle = message, .has = false });

        // A save is rebuilt once: the watcher's notification of the same write adds no rebuild
        if (client) {
            try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 3 }, .contentChanges = &.{.{ .text = v3 }} });
            try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = main_path, .data = v3 });
            const builds = compiles(&h);
            try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
            try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = main_uri, .type = 2 }} });
            _ = try h.request("zig-analyzer/waitIdle", {});
            try testing.expectEqual(builds + 1, compiles(&h));
            try testing.expect(try lastHas(&h, main_uri, message));
        }

        // An open build.zig rewritten on disk restarts the project
        const build_path = try project.path(a, "build.zig");
        const build_uri = try za.base.uri.fromPath(a, build_path);
        try open(&h, build_uri, check_build);
        _ = try h.request("zig-analyzer/waitIdle", {});
        const instance = visibleInstance(&h);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = check_build ++ "// changed\n" });
        if (client) try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = build_uri, .type = 2 }} });
        try waitWatched(&h, Restarted{ .from = instance });

        _ = try h.request("shutdown", {});
        try h.notify("exit", {});
    }
}

/// Condition for `waitWatched`: the project instance is no longer `from`
const Restarted = struct {
    from: *Workspace,

    fn done(c: Restarted, h: *Harness) !bool {
        return visibleInstance(h) != c.from;
    }
};

// Prevents a deleted file that was only read from disk (imported in single-file mode) from keeping
// its old text: its absence equals the never-set text, which must still replace the read
test "a deleted imported file of a single file is no longer resolved" {
    const main_text = "const lib = @import(\"lib.zig\");\npub fn main() void {\n    const n = lib.compute(3);\n    _ = n;\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "lib.zig", .text = "pub fn compute(x: u32) u32 {\n    return x * 2;\n}\npub const answer: u8 = 42;\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{
        .rootUri = root_uri,
        .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } },
        .initializationOptions = .{ .files = .{ .watcher = "client" } },
    });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("lib.zig", try gotoFile(&h, main_uri, main_text, "lib.comp"));
    try testing.expectEqualStrings("compute answer", try completionLabels(&h, main_uri, main_text, "= lib."));

    const lib_path = try project.path(a, "lib.zig");
    try std.Io.Dir.cwd().deleteFile(testing.io, lib_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = try za.base.uri.fromPath(a, lib_path), .type = 3 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("null", try gotoFile(&h, main_uri, main_text, "lib.comp"));
    try testing.expectEqualStrings("", try completionLabels(&h, main_uri, main_text, "= lib."));

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Line of the goto result (-1 without a result)
fn gotoLine(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) !i64 {
    const resp = try h.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = position(text, needle) });
    const result = resp.object.get("result") orelse return -1;
    if (result != .object) return -1;
    return result.object.get("range").?.object.get("start").?.object.get("line").?.integer;
}

/// Condition for `waitWatched`: the goto result of `needle` is on line `want`
const GotoLine = struct {
    uri: []const u8,
    text: []const u8,
    needle: []const u8,
    want: i64,

    fn done(c: GotoLine, h: *Harness) !bool {
        return try gotoLine(h, c.uri, c.text, c.needle) == c.want;
    }
};

// Prevents leaving files outside the workspace folders unwatched when the client registers file
// watchers: clients apply them inside the workspace folders only
test "with a client that registers file watchers, the server watches the files outside the workspace folders" {
    const main_text = "const util = @import(\"../libs/util.zig\");\npub fn main() void {\n    util.helper();\n}\n";
    inline for (.{ false, true }) |with_folder| {
        var project = try fixture.Project.create(&.{
            .{ .path = "app/main.zig", .text = main_text },
            .{ .path = "libs/util.zig", .text = "pub fn helper() void {}\n" },
        });
        defer project.deinit();
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        const a = h.arena.allocator();
        const capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true, .relativePatternSupport = true } } };
        if (with_folder) {
            const app_uri = try za.base.uri.fromPath(a, try project.path(a, "app"));
            _ = try h.request("initialize", .{ .rootUri = app_uri, .workspaceFolders = &.{.{ .uri = app_uri, .name = "app" }}, .capabilities = capabilities });
        } else {
            _ = try h.request("initialize", .{ .capabilities = capabilities });
        }
        try h.notify("initialized", Empty{});
        const main_uri = try za.base.uri.fromPath(a, try project.path(a, "app/main.zig"));
        try open(&h, main_uri, main_text);
        _ = try h.request("zig-analyzer/waitIdle", {});
        try testing.expectEqual(0, try gotoLine(&h, main_uri, main_text, "util.help"));

        // Rewritten outside the editor, and the client sends no notification
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try project.path(a, "libs/util.zig"), .data = "// one\n// two\npub fn helper() void {}\n" });
        try waitWatched(&h, GotoLine{ .uri = main_uri, .text = main_text, .needle = "util.help", .want = 2 });

        _ = try h.request("shutdown", {});
        try h.notify("exit", {});
    }
}

/// Whether the client was asked to watch `glob`
fn registeredGlob(h: *Harness, glob: []const u8) bool {
    for (h.received.items) |m| {
        const method = m.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "client/registerCapability")) continue;
        for (m.object.get("params").?.object.get("registrations").?.array.items) |r| {
            const options = r.object.get("registerOptions") orelse continue;
            for (options.object.get("watchers").?.array.items) |watcher| {
                if (std.mem.eql(u8, watcher.object.get("globPattern").?.string, glob)) return true;
            }
        }
    }
    return false;
}

// Prevents missing folder renames and deletes in the client's watch mode: clients report a folder by
// its own path only, which must be registered and must reach the files under it
test "a folder renamed on disk is registered with the client and its files follow the disk" {
    const main_text = "const inner = @import(\"sub/inner.zig\");\npub fn main() void {\n    const v = inner.innerValue;\n    _ = v;\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = check_build },
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/sub/inner.zig", .text = "pub const innerValue: u32 = 1;\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{
        .rootUri = root_uri,
        .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } },
        .initializationOptions = .{ .files = .{ .watcher = "client" } },
    });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("inner.zig", try gotoFile(&h, main_uri, main_text, "inner.inner"));
    // Registered by a background task once the file is interned
    while (!registeredGlob(&h, "**/sub")) _ = try h.next();

    // Renamed away: the client reports the two folders only
    const sub_path = try project.path(a, "src/sub");
    const moved_path = try project.path(a, "src/moved");
    const sub_uri = try za.base.uri.fromPath(a, sub_path);
    const moved_uri = try za.base.uri.fromPath(a, moved_path);
    try std.Io.Dir.cwd().rename(sub_path, std.Io.Dir.cwd(), moved_path, testing.io);
    const builds = compiles(&h);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{ .{ .uri = sub_uri, .type = 3 }, .{ .uri = moved_uri, .type = 1 } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("null", try gotoFile(&h, main_uri, main_text, "inner.inner"));
    try testing.expect(compiles(&h) > builds);

    // Edited while away and renamed back
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try project.path(a, "src/moved/inner.zig"), .data = "pub const innerValue: u64 = 2;\n" });
    try std.Io.Dir.cwd().rename(moved_path, std.Io.Dir.cwd(), sub_path, testing.io);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{ .{ .uri = moved_uri, .type = 3 }, .{ .uri = sub_uri, .type = 1 } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const at = position(main_text, "inner.inner");
    try testing.expect(std.mem.indexOf(u8, try hoverText(&h, main_uri, at.line, at.character), "u64") != null);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

// Prevents leaving files unwatched when the client rejects the registration of file watchers
test "a client that rejects the registration of file watchers leaves the watching to the server" {
    const main_text = "const util = @import(\"util.zig\");\npub fn main() void {\n    util.add(1, 2);\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "util.zig", .text = "pub fn add(a: u32, b: u32) void {\n    _ = a + b;\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    h.hold_requests = true;
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } } });
    try h.notify("initialized", Empty{});
    const id = while (true) {
        const m = try h.next();
        const method = m.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "client/registerCapability")) break m.object.get("id").?;
    };
    h.hold_requests = false;
    try h.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32603, .message = "cannot watch files" } });
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, try gotoLine(&h, main_uri, main_text, "util.ad"));

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try project.path(a, "util.zig"), .data = "// one\n// two\npub fn add(a: u32, b: u32) void {\n    _ = a + b;\n}\n" });
    try waitWatched(&h, GotoLine{ .uri = main_uri, .text = main_text, .needle = "util.ad", .want = 2 });

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// The root directories of the server
fn roots(h: *Harness) ![]const []const u8 {
    h.server.roots_mutex.lockUncancelable(testing.io);
    defer h.server.roots_mutex.unlock(testing.io);
    return h.arena.allocator().dupe([]const u8, h.server.roots.items);
}

// Prevents ignoring the deprecated `rootPath` of clients that send no `rootUri`
test "initialize takes rootPath as the root when there is no rootUri, and rootUri wins over it" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = check_build },
        .{ .path = "src/main.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/util.zig", .text = "pub fn f() void {}\n" },
    });
    defer project.deinit();
    inline for (.{ false, true }) |with_uri| {
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        const a = h.arena.allocator();
        if (with_uri) {
            const src_uri = try za.base.uri.fromPath(a, try project.path(a, "src"));
            _ = try h.request("initialize", .{ .rootUri = src_uri, .rootPath = project.root, .capabilities = Empty{} });
        } else {
            _ = try h.request("initialize", .{ .rootPath = project.root, .capabilities = Empty{} });
        }
        try h.notify("initialized", Empty{});
        _ = try h.request("zig-analyzer/waitIdle", {});
        const found = try roots(&h);
        try testing.expectEqual(1, found.len);
        try testing.expectEqualStrings(if (with_uri) try project.path(a, "src") else project.root, found[0]);
        try testing.expect(try (Projects{ .n = if (with_uri) 0 else 1 }).done(&h));
        _ = try h.request("shutdown", {});
        try h.notify("exit", {});
    }
}

// Prevents keeping the old text of closed files changed while nobody watched them, once the server
// starts watching after a change of `files.watcher`
test "switching files.watcher to the server compares the files with the disk" {
    const main_text = "const dep = @import(\"dep.zig\");\npub fn main() void {\n    const v = dep.value;\n    _ = v;\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = check_build },
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/dep.zig", .text = "pub const value: u32 = 1;\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    // Nobody watches the files: the client cannot, and the server is told not to
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = .{ .files = .{ .watcher = "client" } } });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, try gotoLine(&h, main_uri, main_text, "dep.val"));

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try project.path(a, "src/dep.zig"), .data = "// a\n// b\n// c\npub const value: i64 = 1;\n" });
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .files = .{ .watcher = "auto" } } } });
    try waitWatched(&h, GotoLine{ .uri = main_uri, .text = main_text, .needle = "dep.val", .want = 3 });

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
