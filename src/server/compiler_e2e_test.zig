//! End-to-end: Server + the real build system protocol; checks that the published diagnostics
//! agree with the compiler, as well as the build progress notifications.

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;
const live = @import("../database.zig").live;

/// Empty object (`.{}` is an empty tuple, which would be serialized as `[]`)
const Empty = struct {};

const Diagnostics = std.StringArrayHashMapUnmanaged([]const []const u8);

fn expectDiagnostics(map: Diagnostics, file: []const u8, expected: []const []const u8) !void {
    const actual = map.get(file) orelse {
        std.debug.print("{s}: no diagnostics published\n", .{file});
        return error.TestUnexpectedResult;
    };
    if (actual.len != expected.len) {
        std.debug.print("{s} diagnostics:\n", .{file});
        for (actual) |l| std.debug.print("  {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
    for (expected, actual) |e, a| {
        if (std.mem.indexOf(u8, a, e) == null) {
            std.debug.print("expected to contain \"{s}\", got \"{s}\"\n", .{ e, a });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectNoErrors(h: *Harness, document_uri: []const u8) !void {
    for (try h.notifications("textDocument/publishDiagnostics")) |message| {
        const params = message.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, document_uri)) continue;
        for (params.get("diagnostics").?.array.items) |diagnostic| {
            const severity = diagnostic.object.get("severity") orelse continue;
            try testing.expect(severity.integer != 1);
        }
    }
}

fn initialize(h: *Harness, root: []const u8, progress: bool) !void {
    return initializeWith(h, root, progress, null);
}

fn initializeWith(h: *Harness, root: []const u8, progress: bool, options: ?std.json.Value) !void {
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .window = .{ .workDoneProgress = progress } }, .initializationOptions = options });
    try h.notify("initialized", Empty{});
}

fn jsonValue(h: *Harness, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), text, .{});
}

fn open(h: *Harness, path: []const u8, text: []const u8) ![]const u8 {
    const uri = try za.base.uri.fromPath(h.arena.allocator(), path);
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    return uri;
}

fn waitIdle(h: *Harness) !void {
    _ = try h.request("zig-analyzer/waitIdle", {});
}

fn shutdown(h: *Harness) !void {
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Titles of all begin progress notifications
fn progressTitles(h: *Harness) ![]const []const u8 {
    var titles: std.ArrayList([]const u8) = .empty;
    for (try h.notifications("$/progress")) |m| {
        const value = m.object.get("params").?.object.get("value").?.object;
        if (std.mem.eql(u8, value.get("kind").?.string, "begin")) try titles.append(h.arena.allocator(), value.get("title").?.string);
    }
    return titles.items;
}

test "compiler diagnostics: build, remap of unsaved edits, rebuild on save, build progress" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    const a = testing.allocator;

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, true);

    const main_path = try project.path(h.arena.allocator(), "src/main.zig");
    const main_text = fixture.basic[1].text;
    const main_uri = try open(&h, main_path, main_text);
    try waitIdle(&h);

    // 1. After opening: the buffer matches the disk and main.zig has only the compiler's Sema
    //    error; files that are not open also have compiler diagnostics
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"2:19 zig: expected type 'u32'"});
    try expectDiagnostics(diags, "lib.zig", &.{"1:8 zig: unused local variable"});
    try expectDiagnostics(diags, "orphan.zig", &.{"1:8 zig: unused local variable"});
    try testing.expect(diags.get("unrelated.zig") == null);

    // 2. Unsaved edit: the Sema error moves down with the inserted line
    const edited = try std.mem.concat(a, u8, &.{ "// a new line\n", main_text });
    defer a.free(edited);
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 2 }, .contentChanges = &.{.{ .text = edited }} });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:19 zig: expected type 'u32'"});

    // 3. Fix the error, write it to disk and save: after the rebuild, the diagnostics of main.zig
    //    are cleared. The compiler can now go on to analyze lib.hello() and reports one more Sema
    //    error in lib.zig (the same result as running zig build check directly).
    const fixed = try std.mem.replaceOwned(u8, a, edited, "const x: u32 = \"not a number\";", "const x: u32 = 1;");
    defer a.free(fixed);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = fixed });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 3 }, .contentChanges = &.{.{ .text = fixed }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{});
    try expectDiagnostics(diags, "lib.zig", &.{
        "1:8 zig: unused local variable",
        "1:8 zig: variable of type 'comptime_int' must be const or comptime",
    });
    try shutdown(&h);

    // 4. Progress: project loading and two builds, each with begin and end; builds have percentages
    const titles = try progressTitles(&h);
    var ends: usize = 0;
    var percentages: usize = 0;
    for (try h.notifications("$/progress")) |m| {
        const value = m.object.get("params").?.object.get("value").?.object;
        const kind = value.get("kind").?.string;
        if (std.mem.eql(u8, kind, "end")) ends += 1;
        if (std.mem.eql(u8, kind, "report") and value.get("percentage") != null) percentages += 1;
    }
    try testing.expect(titles.len >= 3);
    try testing.expect(std.mem.startsWith(u8, titles[0], "Loading project"));
    var builds: usize = 0;
    for (titles) |t| {
        if (std.mem.eql(u8, t, "zig build check")) builds += 1;
    }
    // There is one more build when maker crashes and is restarted automatically
    try testing.expect(builds >= 2);
    if (titles.len != ends) {
        for (try h.notifications("$/progress")) |m| {
            const params = m.object.get("params").?.object;
            const value = params.get("value").?.object;
            std.debug.print("  {s} {s} {s}\n", .{ params.get("token").?.string, value.get("kind").?.string, if (value.get("title")) |t| t.string else if (value.get("message")) |x| (if (x == .string) x.string else "") else "" });
        }
    }
    try testing.expectEqual(titles.len, ends);
    try testing.expect(percentages >= 2);
}

test "compiler diagnostics: a save while the finished build is being published starts another build" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    const a = testing.allocator;

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, true);
    const main_path = try project.path(h.arena.allocator(), "src/main.zig");
    const main_text = fixture.basic[1].text;
    const main_uri = try open(&h, main_path, main_text);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"2:19 zig: expected type 'u32'"});

    // Save the fixed file as soon as the build progress ends: the server is then still publishing
    // the results of this round and recomputing the compile set
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
    var build_token: ?[]const u8 = null;
    while (true) {
        const msg = try h.next();
        const method = msg.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "$/progress")) continue;
        const params = msg.object.get("params").?.object;
        const token = params.get("token").?.string;
        const value = params.get("value").?.object;
        const kind = value.get("kind").?.string;
        if (std.mem.eql(u8, kind, "begin") and std.mem.startsWith(u8, value.get("title").?.string, "zig build")) build_token = token;
        if (std.mem.eql(u8, kind, "end") and build_token != null and std.mem.eql(u8, token, build_token.?)) break;
    }
    const fixed = try std.mem.replaceOwned(u8, a, main_text, "const x: u32 = \"not a number\";", "const x: u32 = 1;");
    defer a.free(fixed);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = fixed });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 2 }, .contentChanges = &.{.{ .text = fixed }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
    try waitIdle(&h);
    // If the build request for this save is lost, main.zig still shows the already fixed error
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{});
    try shutdown(&h);
}

fn countRequests(h: *Harness, method: []const u8) usize {
    var n: usize = 0;
    for (h.received.items) |m| {
        if (m.object.get("id") == null) continue;
        const mm = m.object.get("method") orelse continue;
        if (std.mem.eql(u8, mm.string, method)) n += 1;
    }
    return n;
}

test "progress: nothing is sent when the client rejects the token" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    h.reject_requests = true;
    try initialize(&h, project.root, true);
    try waitIdle(&h);
    try shutdown(&h);
    try testing.expectEqual(0, (try h.notifications("$/progress")).len);
    try testing.expect(countRequests(&h, "window/workDoneProgress/create") >= 2);
}

test "progress: no create request when the client does not support it" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    try shutdown(&h);
    try testing.expectEqual(0, countRequests(&h, "window/workDoneProgress/create"));
}

const simple_build =
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

/// Only opens the project and waits for the build, then returns the diagnostics last published
/// for each file
fn runProject(h: *Harness, project: *fixture.Project) !Diagnostics {
    try initialize(h, project.root, false);
    try waitIdle(h);
    try shutdown(h);
    return h.diagnostics();
}

test "compile errors in build.zig itself are published on build.zig" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\    _ = b;
        \\}
        \\
        },
        .{ .path = "main.zig", .text = "pub fn main() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const diags = try runProject(&h, &project);
    try expectDiagnostics(diags, "build.zig", &.{"2:19 zig: expected type 'u32'"});
}

const scripts_build =
    \\const std = @import("std");
    \\const helper = @import("build/helper.zig");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = helper.name(), .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;
const scripts_helper = "pub fn name() []const u8 {\n    return \"demo\";\n}\n";
const scripts_zon = ".{\n    .name = .demo,\n    .version = \"0.0.0\",\n    .fingerprint = 0xd642dfa0858809cc,\n    .paths = .{\"\"},\n}\n";

fn change(h: *Harness, uri: []const u8, version: i64, text: []const u8) !void {
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = text }} });
}

test "build scripts: live diagnostics in build.zig, build.zig.zon and files build.zig imports, changes to them reconfigure" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = scripts_build },
        .{ .path = "build/helper.zig", .text = scripts_helper },
        .{ .path = "build.zig.zon", .text = scripts_zon },
        .{ .path = "main.zig", .text = "pub fn main() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, project.root, false);
    const build_uri = try open(&h, try project.path(a, "build.zig"), scripts_build);
    const helper_path = try project.path(a, "build/helper.zig");
    const helper_uri = try open(&h, helper_path, scripts_helper);
    const zon_path = try project.path(a, "build.zig.zon");
    const zon_uri = try open(&h, zon_path, scripts_zon);
    try waitIdle(&h);
    try testing.expect(h.server.workspaces.items[0].compile_set != null);

    // Unsaved syntax error: it gets live diagnostics just like files in the compile set
    try change(&h, build_uri, 2, try std.mem.replaceOwned(u8, a, scripts_build, "@import(\"std\");", "@import(\"std\")"));
    try change(&h, helper_uri, 2, try std.mem.replaceOwned(u8, a, scripts_helper, "\"demo\";", "\"demo\""));
    try change(&h, zon_uri, 2, try std.mem.replaceOwned(u8, a, scripts_zon, "\"0.0.0\",", "\"0.0.0\""));
    try waitIdle(&h);
    const diags = try h.diagnostics();
    try expectDiagnostics(diags, "build.zig", &.{"zig ast-check: expected ';' after declaration"});
    try expectDiagnostics(diags, "helper.zig", &.{"zig ast-check: expected ';' after statement"});
    try expectDiagnostics(diags, "build.zig.zon", &.{"zig ast-check: expected ',' after initializer"});
    try change(&h, build_uri, 3, scripts_build);
    try change(&h, zon_uri, 3, scripts_zon);

    // Save a file that build.zig imports: the project is reconfigured, and the compile error of
    // the build program is published on that file
    const bad_helper = try std.mem.replaceOwned(u8, a, scripts_helper, "\"demo\"", "42");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = helper_path, .data = bad_helper });
    try change(&h, helper_uri, 3, bad_helper);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = helper_uri } });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "helper.zig", &.{"zig: expected type '[]const u8', found 'comptime_int'"});

    // Change it outside the editor: the project is reconfigured likewise
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = helper_uri } });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = helper_path, .data = try std.mem.replaceOwned(u8, a, scripts_helper, "\"demo\"", "true") });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = helper_uri, .type = 2 }} });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "helper.zig", &.{"zig: expected type '[]const u8', found 'bool'"});

    // Errors in build.zig.zon are not among the errors maker sends: they are taken from its
    // stderr and published on build.zig.zon
    const bad_zon = try std.mem.replaceOwned(u8, a, scripts_zon, "0xd642dfa0858809cc", "0x1");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = zon_path, .data = bad_zon });
    try change(&h, zon_uri, 4, bad_zon);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = zon_uri } });
    try waitIdle(&h);
    try testing.expect(anyContains((try h.diagnostics()).get("build.zig.zon").?, "0:1 zig: invalid fingerprint: 0x1;"));
    try testing.expect(!anyContains(try shownMessages(&h), "zig build cannot load"));
    try shutdown(&h);
}

test "columns are UTF-16 when multi-byte characters precede the error" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = simple_build },
        .{ .path = "main.zig", .text =
        \\pub fn main() void {
        \\    const s = "€€😀"; const x: u32 = s;
        \\    _ = x;
        \\}
        \\
        },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const diags = try runProject(&h, &project);
    // `s` is at byte column 43 and UTF-16 column 37 (each of the two euro signs is 3 bytes and
    // 1 code unit, the emoji is 4 bytes and 2 code units)
    try expectDiagnostics(diags, "main.zig", &.{"1:37 zig: expected type 'u32'"});
}

/// Writes zigw, a script wrapping the user's zig, into the project directory: commands other
/// than `env` first wait 2 seconds. Returns the initialization options that use it.
fn slowZig(h: *Harness, project: *fixture.Project) !std.json.Value {
    const zig = project.env.zig_exe;
    const script = try std.fmt.allocPrint(h.arena.allocator(),
        \\#!/bin/sh
        \\if [ "$1" = env ]; then exec "{s}" "$@"; fi
        \\sleep 2
        \\exec "{s}" "$@"
        \\
    , .{ zig, zig });
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });
    return jsonValue(h, try std.fmt.allocPrint(h.arena.allocator(), "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{project.root}));
}

test "single-file mode: compile one file without build.zig, with progress" {
    const text =
        \\pub fn main() void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, true);
    try waitIdle(&h);
    _ = try open(&h, try project.path(h.arena.allocator(), "one.zig"), text);
    try waitIdle(&h);
    try shutdown(&h);
    try expectDiagnostics(try h.diagnostics(), "one.zig", &.{"1:19 zig: expected type 'u32'"});
    const titles = try progressTitles(&h);
    try testing.expect(titles.len >= 1);
    try testing.expectEqualStrings("Compiling one.zig", titles[0]);
}

test "single-file mode: disabling compiler diagnostics during a compile drops its result" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const text =
        \\pub fn main() void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, true, try slowZig(&h, &project));
    const uri = try open(&h, try project.path(h.arena.allocator(), "one.zig"), text);
    // Wait until the compiler task starts (the wrapper script still sleeps 2 seconds after that)
    while (true) {
        const m = try h.next();
        const method = if (m.object.get("method")) |x| x.string else continue;
        if (!std.mem.eql(u8, method, "$/progress")) continue;
        const value = m.object.get("params").?.object.get("value").?.object;
        if (!std.mem.eql(u8, value.get("kind").?.string, "begin")) continue;
        if (std.mem.eql(u8, value.get("title").?.string, "Compiling one.zig")) break;
    }
    // Disable compiler diagnostics before the compile finishes: the results of the old task
    // must be discarded
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"zig-analyzer": {"diagnostics": {"compiler": false}}}
    ) });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "one.zig", &.{});
    try expectNoErrors(&h, uri);
    try shutdown(&h);
}

test "single-file mode: closing a file without errors drops its result" {
    const text = "pub fn main() void {}\n";
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    const uri = try open(&h, try project.path(h.arena.allocator(), "one.zig"), text);
    try waitIdle(&h);
    {
        h.server.single_mutex.lockUncancelable(testing.io);
        defer h.server.single_mutex.unlock(testing.io);
        try testing.expectEqual(1, h.server.single.count());
    }
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
    try waitIdle(&h);
    {
        h.server.single_mutex.lockUncancelable(testing.io);
        defer h.server.single_mutex.unlock(testing.io);
        try testing.expectEqual(0, h.server.single.count());
    }
    try shutdown(&h);
}

test "inactive hints are not published inside compiler errors" {
    const text =
        \\const builtin = @import("builtin");
        \\export fn entry() u32 {
        \\    if (builtin.is_test) {
        \\        const unused = 1;
        \\        return 0;
        \\    } else {
        \\        return 1;
        \\    }
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"diagnostics": {"inactive_code": true}}
    ));
    try waitIdle(&h);
    const uri = try open(&h, try project.path(h.arena.allocator(), "one.zig"), text);
    try waitIdle(&h);
    var last: ?[]const std.json.Value = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |message| {
        const params = message.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
        last = params.get("diagnostics").?.array.items;
    }
    var saw_compiler_error = false;
    for (last orelse return error.NoDiagnostics) |d| {
        const source = d.object.get("source").?.string;
        if (std.mem.eql(u8, source, "zig")) saw_compiler_error = true;
        try testing.expect(!std.mem.eql(u8, source, "zig-analyzer") or
            std.mem.indexOf(u8, d.object.get("message").?.string, "code is inactive") == null);
    }
    try testing.expect(saw_compiler_error);
    try shutdown(&h);
}

test "files of the zig installation are not standalone compilation roots during startup or save" {
    const text =
        \\pub fn main() void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const std_path = try std.fs.path.join(a, &.{ project.env.std_dir, "std.zig" });
    const std_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, std_path, a, .limited(2 * 1024 * 1024));
    try initialize(&h, project.root, true);
    const std_uri = try open(&h, std_path, std_text);
    try waitIdle(&h);
    try expectNoErrors(&h, std_uri);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = std_uri } });
    // Files outside the standard library likewise take part in compiles only as dependencies:
    // compiling them alone lacks the modules and builtin members provided by the build system
    var lib_uris: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "configurer.zig", "test_runner.zig" }) |name| {
        const path = try std.fs.path.join(a, &.{ project.env.lib_dir, "compiler", name });
        const lib_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(2 * 1024 * 1024));
        try lib_uris.append(a, try open(&h, path, lib_text));
    }
    _ = try open(&h, try project.path(a, "one.zig"), text);
    try waitIdle(&h);
    const diags = try h.diagnostics();
    try expectNoErrors(&h, std_uri);
    for (lib_uris.items) |u| try expectNoErrors(&h, u);
    try expectDiagnostics(diags, "one.zig", &.{"1:19 zig: expected type 'u32'"});
    try shutdown(&h);
    for (try progressTitles(&h)) |title| {
        if (std.mem.startsWith(u8, title, "Compiling ")) try testing.expectEqualStrings("Compiling one.zig", title);
    }
}

test "single-file mode: errors a root reports in the standard library are published there, also once a project is added" {
    const bad =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    std.debug.print("{d}\n", .{});
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{
        .{ .path = "scratch/one.zig", .text = bad },
        .{ .path = "proj/build.zig", .text = simple_build },
        .{ .path = "proj/main.zig", .text = "pub fn main() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "scratch"), false);
    const one_path = try project.path(a, "scratch/one.zig");
    const one_uri = try open(&h, one_path, bad);
    try waitIdle(&h);
    // The error is located in the standard library, and one.zig itself has no error: it is
    // published on the standard library file
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "one.zig", &.{});
    try expectDiagnostics(diags, "Writer.zig", &.{"zig: too few arguments"});

    // Add a project: the standard library is also in its compile set, and the single-file compile
    // results are still used for the standard library files
    const proj_uri = try za.base.uri.fromPath(a, try project.path(a, "proj"));
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &.{.{ .uri = proj_uri, .name = "proj" }}, .removed = &[_]Empty{} } });
    try waitIdle(&h);
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "Writer.zig", &.{"zig: too few arguments"});

    // Fix and save one.zig: the error in the standard library is cleared along with it
    const fixed = try std.mem.replaceOwned(u8, a, bad, ".{});", ".{1});");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = one_path, .data = fixed });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = one_uri, .version = 2 }, .contentChanges = &.{.{ .text = fixed }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = one_uri } });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "one.zig", &.{});
    try expectDiagnostics(diags, "Writer.zig", &.{});
    try shutdown(&h);
}

/// Modules outside the build root (project): dep.zig imports support by name, which can only be
/// resolved in the project's module graph
const outside_root = [_]fixture.File{
    .{ .path = "project/build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const support = b.createModule(.{ .root_source_file = .{ .cwd_relative = "../dependency/support.zig" } });
    \\    const dep = b.createModule(.{
    \\        .root_source_file = .{ .cwd_relative = "../dependency/dep.zig" },
    \\        .imports = &.{.{ .name = "support", .module = support }},
    \\    });
    \\    const root = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "dep", .module = dep }},
    \\    });
    \\    b.step("check", "Check").dependOn(&b.addObject(.{ .name = "probe", .root_module = root }).step);
    \\}
    \\
    },
    .{ .path = "project/main.zig", .text = "export fn entry() u32 {\n    return @import(\"dep\").value();\n}\n" },
    .{ .path = "dependency/dep.zig", .text = dep_good },
    .{ .path = "dependency/support.zig", .text = support_text },
};
const dep_good = "const support = @import(\"support\");\npub fn value() u32 {\n    return support.answer;\n}\n";
const dep_bad = "const support = @import(\"support\");\npub fn value() u32 {\n    _ = support.answer;\n    return \"bad\";\n}\n";
const support_text = "pub const answer: u32 = 1;\n";

fn countTitles(titles: []const []const u8, title: []const u8) usize {
    var n: usize = 0;
    for (titles) |t| {
        if (std.mem.eql(u8, t, title)) n += 1;
    }
    return n;
}

/// Saves a file: writes it to disk, syncs the buffer, then notifies the save
fn save(h: *Harness, path: []const u8, file_uri: []const u8, version: i64, text: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = text });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = file_uri, .version = version }, .contentChanges = &.{.{ .text = text }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = file_uri } });
}

test "modules outside the build root: never compiled alone, saving them rebuilds the project, renamable" {
    var project = try fixture.Project.create(&outside_root);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "project"), true);
    // Opened while the project is loading: it is not yet known that dep.zig belongs to the
    // project, so the single-file compile is postponed until loading ends, by which time it
    // has been assigned to the project
    const dep_path = try project.path(a, "dependency/dep.zig");
    const dep_uri = try open(&h, dep_path, dep_good);
    try waitIdle(&h);
    // Opened after loading
    _ = try open(&h, try project.path(a, "dependency/support.zig"), support_text);
    try waitIdle(&h);
    const builds = countTitles(try progressTitles(&h), "zig build check");
    try testing.expect(builds >= 1);

    // Save only dep.zig: the project is rebuilt and the error is reported in the real module
    // graph (rather than support not being found)
    try save(&h, dep_path, dep_uri, 2, dep_bad);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "dep.zig", &.{"3:11 zig: expected type 'u32'"});
    try testing.expect(countTitles(try progressTitles(&h), "zig build check") > builds);

    // User code outside the root directory that belongs to the project can be renamed
    const prepared = try h.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = dep_uri }, .position = .{ .line = 1, .character = 8 } });
    try testing.expect(prepared.object.get("error") == null);
    try testing.expect(prepared.object.get("result").? != .null);

    // After the fix, again save only dep.zig: the error is cleared
    try save(&h, dep_path, dep_uri, 3, dep_good);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "dep.zig", &.{});
    try shutdown(&h);
    for (try progressTitles(&h)) |title| try testing.expect(!std.mem.startsWith(u8, title, "Compiling"));
}

/// Projects that share shared/x.zig through an absolute path (relative to the build root)
const shared_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const shared = b.createModule(.{ .root_source_file = .{ .cwd_relative = "../shared/x.zig" } });
    \\    const root = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "shared", .module = shared }},
    \\    });
    \\    b.step("check", "Check").dependOn(&b.addObject(.{ .name = "probe", .root_module = root }).step);
    \\}
    \\
;
const shared_good = "pub fn fine() u32 {\n    return 1;\n}\npub fn broken() u32 {\n    return 2;\n}\n";
const shared_bad = "pub fn fine() u32 {\n    return 1;\n}\npub fn broken() u32 {\n    return \"x\";\n}\n";

test "a module shared by two projects: saving it rebuilds both, the errors of either build are published" {
    var project = try fixture.Project.create(&.{
        // b does not call broken: its build does not analyze the error in it
        .{ .path = "b/build.zig", .text = shared_build },
        .{ .path = "b/main.zig", .text = "export fn entry() u32 {\n    return @import(\"shared\").fine();\n}\n" },
        .{ .path = "a/build.zig", .text = shared_build },
        .{ .path = "a/main.zig", .text = "export fn entry() u32 {\n    return @import(\"shared\").broken();\n}\n" },
        .{ .path = "shared/x.zig", .text = shared_good },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const folders = [_]struct { uri: []const u8, name: []const u8 }{
        .{ .uri = try za.base.uri.fromPath(a, try project.path(a, "b")), .name = "b" },
        .{ .uri = try za.base.uri.fromPath(a, try project.path(a, "a")), .name = "a" },
    };
    _ = try h.request("initialize", .{ .capabilities = .{ .window = .{ .workDoneProgress = true } }, .workspaceFolders = &folders });
    try h.notify("initialized", Empty{});
    const x_path = try project.path(a, "shared/x.zig");
    const x_uri = try open(&h, x_path, shared_good);
    try waitIdle(&h);
    try testing.expectEqual(2, h.server.workspaces.items.len);
    try testing.expect(std.mem.endsWith(u8, h.server.workspaces.items[0].root, "b"));
    const builds = countTitles(try progressTitles(&h), "zig build check");

    // Only the build of a reports the error in x.zig; the first project containing x.zig is b
    try save(&h, x_path, x_uri, 2, shared_bad);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "x.zig", &.{"4:11 zig: expected type 'u32'"});
    try testing.expect(countTitles(try progressTitles(&h), "zig build check") >= builds + 2);

    try save(&h, x_path, x_uri, 3, shared_good);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "x.zig", &.{});
    try shutdown(&h);
    for (try progressTitles(&h)) |title| try testing.expect(!std.mem.startsWith(u8, title, "Compiling"));
}

/// Dependency package fetched by hash (faked: maker does not fetch it again when the package
/// directory already has it). The project uses `--pkg-dir` to put the package directory outside
/// the build root.
const fetched_hash = "foo-0.0.1-OjQ08eFlFQAb4BLnwZNNE3R5Dx2TI67EIpAsy2h0ZyoC";
const fetched_package = [_]fixture.File{
    .{ .path = "proj/build.zig.zon", .text = ".{ .name = .proj, .version = \"0.0.0\", .fingerprint = 0x520c3c90be36badb, .paths = .{\"\"}, " ++
        ".dependencies = .{ .foo = .{ .url = \"https://example.invalid/foo.tar.gz\", .hash = \"" ++ fetched_hash ++ "\" } } }\n" },
    .{ .path = "proj/build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const foo = b.dependency("foo", .{});
    \\    const root = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "foo", .module = foo.module("foo") }},
    \\    });
    \\    b.step("check", "Check").dependOn(&b.addObject(.{ .name = "probe", .root_module = root }).step);
    \\}
    \\
    },
    .{ .path = "proj/main.zig", .text = "export fn entry() u32 {\n    return @import(\"foo\").answer();\n}\n" },
    .{ .path = "proj/zig-analyzer.zon", .text = ".{ .build = .{ .args = .{ \"--pkg-dir\", \"../pkgs\" } } }" },
    .{ .path = "pkgs/" ++ fetched_hash ++ "/build.zig.zon", .text = ".{ .name = .foo, .version = \"0.0.1\", .fingerprint = 0x8c736521e67512df, .paths = .{\"\"} }\n" },
    .{ .path = "pkgs/" ++ fetched_hash ++ "/build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    _ = b.addModule("foo", .{ .root_source_file = b.path("src/root.zig") });
    \\}
    \\
    },
    .{ .path = "pkgs/" ++ fetched_hash ++ "/src/root.zig", .text = fetched_root },
    // A file not used by any module
    .{ .path = "pkgs/" ++ fetched_hash ++ "/src/unused.zig", .text = "const x: u32 = \"s\";\ncomptime {\n    _ = x;\n}\n" },
};
const fetched_root = "pub fn answer() u32 {\n    return 42;\n}\n";

test "fetched packages outside the build root are libraries: never compiled alone, not renamable" {
    var project = try fixture.Project.create(&fetched_package);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "proj"), true);
    try waitIdle(&h);
    {
        const ws = h.server.workspaces.items[0];
        ws.mutex.lockUncancelable(testing.io);
        defer ws.mutex.unlock(testing.io);
        const roots = ws.model.?.package_roots;
        try testing.expectEqual(1, roots.len);
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ project.root, "pkgs", fetched_hash }), roots[0]);
    }
    const pkg = "pkgs/" ++ fetched_hash ++ "/src/";
    try testing.expectEqual(.package, h.server.fileOrigin(try h.server.vfs.intern(try project.path(a, pkg ++ "root.zig"))));
    try testing.expectEqual(.user, h.server.fileOrigin(try h.server.vfs.intern(try project.path(a, "proj/main.zig"))));
    const root_uri = try open(&h, try project.path(a, pkg ++ "root.zig"), fetched_root);
    const unused_path = try project.path(a, pkg ++ "unused.zig");
    const unused_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, unused_path, a, .limited(1024));
    const unused_uri = try open(&h, unused_path, unused_text);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = unused_uri } });
    try waitIdle(&h);
    try expectNoErrors(&h, unused_uri);
    const prepared = try h.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = root_uri }, .position = .{ .line = 0, .character = 9 } });
    try testing.expect(prepared.object.get("error") != null);
    try shutdown(&h);
    for (try progressTitles(&h)) |title| try testing.expect(!std.mem.startsWith(u8, title, "Compiling"));
}

test "workspace symbols list dependency packages only when enabled" {
    var project = try fixture.Project.create(&fetched_package);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "proj"), false);
    try waitIdle(&h);
    // By default, symbols in dependencies are not listed: `answer` in the dependency package is
    // not among them
    const user = try h.request("workspace/symbol", .{ .query = "answer" });
    try testing.expectEqual(0, user.object.get("result").?.array.items.len);
    const entry = try h.request("workspace/symbol", .{ .query = "entry" });
    try testing.expectEqual(1, entry.object.get("result").?.array.items.len);

    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"workspace_symbol": {"dependencies": true}}
    ) });
    try waitIdle(&h);
    const deps = try h.request("workspace/symbol", .{ .query = "answer" });
    const items = deps.object.get("result").?.array.items;
    try testing.expectEqual(1, items.len);
    try testing.expect(std.mem.endsWith(u8, items[0].object.get("location").?.object.get("uri").?.string, "/src/root.zig"));
    try shutdown(&h);
}

test "inspection requests for a project file: file status, module graph, reload restarts the project" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    const main_path = try project.path(a, "src/main.zig");
    const main_uri = try za.base.uri.fromPath(a, main_path);

    const status = (try h.request("zig-analyzer/fileStatus", .{ .textDocument = .{ .uri = main_uri } })).object.get("result").?.object;
    try testing.expectEqualStrings("user", status.get("origin").?.string);
    try testing.expectEqualStrings("project", status.get("context").?.string);
    try testing.expectEqualStrings(main_path, status.get("modules").?.array.items[0].string);
    const projects = status.get("projects").?.array.items;
    try testing.expectEqual(1, projects.len);
    try testing.expectEqualStrings(project.root, projects[0].object.get("root").?.string);
    // The example project has compile errors
    try testing.expect(projects[0].object.get("last_build").?.object.get("diagnostics").?.integer > 0);

    const graph = (try h.request("zig-analyzer/moduleGraph", {})).object.get("result").?.object;
    const main_module = for (graph.get("modules").?.array.items) |m| {
        const root = m.object.get("root").?;
        if (root == .string and std.mem.eql(u8, root.string, main_path)) break m.object;
    } else return error.TestUnexpectedResult;
    for (main_module.get("imports").?.array.items) |imp| {
        if (std.mem.eql(u8, imp.object.get("name").?.string, "lib")) break;
    } else return error.TestUnexpectedResult;

    // Reload: a new instance replaces the old one
    const before = h.server.workspaces.items[0];
    _ = try h.request("zig-analyzer/reloadWorkspace", {});
    try waitIdle(&h);
    try testing.expect(h.server.workspaces.items[0] != before);
    try shutdown(&h);
}

/// Project proj outside the workspace (ws, without build.zig): main.zig imports module dep by
/// name and has a Sema error
const unloaded_project = [_]fixture.File{
    .{ .path = "ws/scratch.zig", .text = "pub fn main() void {}\n" },
    .{ .path = "proj/build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const root = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "dep", .module = b.createModule(.{ .root_source_file = b.path("src/dep.zig") }) }},
    \\    });
    \\    b.step("check", "Check").dependOn(&b.addObject(.{ .name = "probe", .root_module = root }).step);
    \\}
    \\
    },
    .{ .path = "proj/src/main.zig", .text = unloaded_main },
    .{ .path = "proj/src/dep.zig", .text = "pub const name = \"dep\";\n" },
};
const unloaded_main = "const dep = @import(\"dep\");\nexport fn entry() void {\n    const x: u32 = dep.name;\n    _ = x;\n}\n";

test "files of a project outside the workspace: not compiled alone, a hint until the project is added" {
    var project = try fixture.Project.create(&unloaded_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "ws"), false);
    const main_uri = try open(&h, try project.path(a, "proj/src/main.zig"), unloaded_main);
    try waitIdle(&h);
    // Compiling it alone would report that module dep is not found: not compiled, only a hint
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"0:0 zig-analyzer: this file belongs to the project at"});
    const status = (try h.request("zig-analyzer/fileStatus", .{ .textDocument = .{ .uri = main_uri } })).object.get("result").?.object;
    try testing.expectEqualStrings("unloaded_project", status.get("context").?.string);
    try testing.expectEqual(0, status.get("single_file_roots").?.array.items.len);

    // Add the project to the workspace: the hint disappears and the diagnostics come from the
    // project's build
    const proj_uri = try za.base.uri.fromPath(a, try project.path(a, "proj"));
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &.{.{ .uri = proj_uri, .name = "proj" }}, .removed = &[_]Empty{} } });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"2:19 zig: expected type 'u32'"});
    try shutdown(&h);
}

test "single-file mode: errors in imported files are published on them and cleared after a fix" {
    const a_text =
        \\const b = @import("b.zig");
        \\export fn entry() u32 {
        \\    return b.foo(1);
        \\}
        \\
    ;
    const b_text =
        \\const T = u32;
        \\comptime {
        \\    _ = @as(T, "x");
        \\}
        \\pub fn foo(x: u32) u32 {
        \\    const y: T = "s";
        \\    _ = y;
        \\    return x;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{ .{ .path = "a.zig", .text = a_text }, .{ .path = "b.zig", .text = b_text } });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    const arena = h.arena.allocator();

    // Errors that compiling a.zig reports in b.zig are published on b.zig (b.zig is not open yet)
    const a_path = try project.path(arena, "a.zig");
    const a_uri = try open(&h, a_path, a_text);
    try waitIdle(&h);
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "a.zig", &.{});
    try expectDiagnostics(diags, "b.zig", &.{ "2:15 zig: expected type 'u32'", "5:17 zig: expected type 'u32'" });

    // Open b.zig: compiling b.zig alone reports only the error in the comptime block, which is
    // merged with the compile results of a.zig (identical errors are kept only once)
    const b_path = try project.path(arena, "b.zig");
    const b_uri = try open(&h, b_path, b_text);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "b.zig", &.{ "2:15 zig: expected type 'u32'", "5:17 zig: expected type 'u32'" });

    // Fix b.zig away from the error locations and save it: a.zig, which reported errors in
    // b.zig, is recompiled as a result, and all errors are cleared
    const fixed = try std.mem.replaceOwned(u8, arena, b_text, "T = u32", "T = []const u8");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = b_path, .data = fixed });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = b_uri, .version = 2 }, .contentChanges = &.{.{ .text = fixed }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = b_uri } });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "a.zig", &.{});
    try expectDiagnostics(diags, "b.zig", &.{});

    // Change the error back and save: a.zig's last compile read b.zig (though it reported no
    // errors in it), so it is recompiled too
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = b_path, .data = b_text });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = b_uri, .version = 3 }, .contentChanges = &.{.{ .text = b_text }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = b_uri } });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "b.zig", &.{ "2:15 zig: expected type 'u32'", "5:17 zig: expected type 'u32'" });

    // Close a.zig and delete it outside the editor: its compile results are dropped, and b.zig
    // keeps only the errors reported by compiling b.zig alone
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = a_uri } });
    try std.Io.Dir.cwd().deleteFile(testing.io, a_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = a_uri, .type = 3 }} });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "b.zig", &.{"2:15 zig: expected type 'u32'"});

    // Recreate and open a.zig (which has its own error too), then delete it outside the editor
    // before closing it: a.zig is still open when it is deleted, and closing it likewise drops
    // its compile results
    const a_bad = a_text ++ "comptime {\n    _ = @as(u8, 300);\n}\n";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = a_path, .data = a_bad });
    _ = try open(&h, a_path, a_bad);
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "a.zig", &.{"5:16 zig: type 'u8' cannot represent integer value '300'"});
    try expectDiagnostics(diags, "b.zig", &.{ "2:15 zig: expected type 'u32'", "5:17 zig: expected type 'u32'" });
    try std.Io.Dir.cwd().deleteFile(testing.io, a_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = a_uri, .type = 3 }} });
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = a_uri } });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "a.zig", &.{});
    try expectDiagnostics(diags, "b.zig", &.{"2:15 zig: expected type 'u32'"});
    try shutdown(&h);
}

test "single-file mode: a root deleted while it compiles leaves no diagnostics" {
    const text =
        \\comptime {
        \\    _ = @as(u8, 300);
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "a.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, true);
    try waitIdle(&h);
    const path = try project.path(h.arena.allocator(), "a.zig");
    const a_uri = try open(&h, path, text);
    // After the compile starts (the request to create progress), delete a.zig outside the editor
    // and then close it: the results of this compile are no longer published
    while (true) {
        const msg = try h.next();
        const method = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "window/workDoneProgress/create")) break;
    }
    try std.Io.Dir.cwd().deleteFile(testing.io, path);
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = a_uri } });
    try waitIdle(&h);
    try shutdown(&h);
    try expectDiagnostics(try h.diagnostics(), "a.zig", &.{});
}

test "generated module roots: resolved from build results, including modules check does not depend on" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const opts = b.addOptions();
        \\    opts.addOption(u32, "answer", 42);
        \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "build_options", .module = opts.createModule() }},
        \\    }) });
        \\    b.step("check", "Check").dependOn(&exe.step);
        \\
        \\    const test_opts = b.addOptions();
        \\    test_opts.addOption(bool, "in_test", true);
        \\    const tests = b.addTest(.{ .root_module = b.createModule(.{
        \\        .root_source_file = b.path("t.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "test_options", .module = test_opts.createModule() }},
        \\    }) });
        \\    b.step("test", "Test").dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        },
        .{ .path = "main.zig", .text =
        \\const opts = @import("build_options");
        \\pub fn main() void {
        \\    const x: bool = opts.answer;
        \\    _ = x;
        \\}
        \\
        },
        .{ .path = "t.zig", .text = "const o = @import(\"test_options\");\ntest {\n    const x: u8 = o.in_test;\n    _ = x;\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);

    // Compiler diagnostics agree with zig build check: only main.zig's error, and t.zig of the
    // test step has no diagnostics
    const diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"2:20 zig: expected type 'bool', found 'u32'"});
    try testing.expect(diags.get("t.zig") == null);

    const ws = h.server.workspaces.items[0];
    ws.mutex.lockUncancelable(testing.io);
    defer ws.mutex.unlock(testing.io);
    // The paths of both generated module root files (including test_options, which check does
    // not depend on) are known
    var generated: usize = 0;
    for (ws.model.?.modules) |m| {
        if (m.generated_root == null) continue;
        generated += 1;
        try testing.expect(std.mem.endsWith(u8, m.root_file.?, "options.zig"));
        try testing.expect(std.fs.path.isAbsolute(m.root_file.?));
    }
    try testing.expectEqual(2, generated);
    // The compile set contains only the generated files that check uses
    var in_set: usize = 0;
    for (ws.compile_set.?.files.keys()) |f| {
        if (std.mem.endsWith(u8, h.server.vfs.path(f), "options.zig")) in_set += 1;
    }
    try testing.expectEqual(1, in_set);
}

/// Project whose `build_options` is a generated options module
const options_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const opts = b.addOptions();
    \\    opts.addOption(u32, "answer", 42);
    \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "build_options", .module = opts.createModule() }},
    \\    }) });
    \\    b.step("check", "Check").dependOn(&exe.step);
    \\}
    \\
;
const options_main =
    \\const opts = @import("build_options");
    \\pub fn main() void {
    \\    _ = opts.answer;
    \\}
    \\
;

// Guards against always computing the local cache directory as `<build root>/.zig-cache`: when
// `--cache-dir` (or `ZIG_LOCAL_CACHE_DIR`) puts generated files elsewhere, the paths of the
// generated module root files do not exist and none of the names in those modules resolve
test "generated module roots: local cache directory moved with --cache-dir" {
    const main_text = options_main;
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = options_build },
        .{ .path = "main.zig", .text = main_text },
        // Relative paths are relative to the build root
        .{ .path = "zig-analyzer.zon", .text = ".{ .build = .{ .args = .{ \"--cache-dir\", \"altcache\" } } }" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    const a = h.arena.allocator();
    {
        const ws = h.server.workspaces.items[0];
        ws.mutex.lockUncancelable(testing.io);
        defer ws.mutex.unlock(testing.io);
        const cache = try project.path(a, "altcache");
        try testing.expectEqualStrings(cache, ws.model.?.local_cache_root);
        var generated: usize = 0;
        for (ws.model.?.modules) |m| {
            if (m.generated_root == null) continue;
            generated += 1;
            try testing.expect(std.mem.startsWith(u8, m.root_file.?, cache));
            try std.Io.Dir.cwd().access(testing.io, m.root_file.?, .{});
        }
        try testing.expectEqual(1, generated);
    }
    const uri = try open(&h, try project.path(a, "main.zig"), main_text);
    try waitIdle(&h);
    const resp = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 2, .character = 14 } });
    const result = resp.object.get("result").?;
    try testing.expect(result == .object);
    const value = result.object.get("contents").?.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, value, "answer: u32 = 42") != null);
    // Generated files are in altcache under the build root and cannot be renamed (maker would
    // overwrite the changes)
    const rename_at = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 2, .character = 14 } };
    try testing.expect((try h.request("textDocument/prepareRename", rename_at)).object.get("error") != null);
    const rename = .{ .textDocument = rename_at.textDocument, .position = rename_at.position, .newName = "answer2" };
    try testing.expect((try h.request("textDocument/rename", rename)).object.get("error") != null);
    try shutdown(&h);
}

test "generated files in a local cache directory outside the build root: never compiled alone, not renamable" {
    var project = try fixture.Project.create(&.{
        .{ .path = "proj/build.zig", .text = options_build },
        .{ .path = "proj/main.zig", .text = options_main },
        .{ .path = "proj/zig-analyzer.zon", .text = ".{ .build = .{ .args = .{ \"--cache-dir\", \"../cache\" } } }" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "proj"), true);
    try waitIdle(&h);
    const cache = try std.fs.path.join(a, &.{ project.root, "cache" });
    const generated = blk: {
        const ws = h.server.workspaces.items[0];
        ws.mutex.lockUncancelable(testing.io);
        defer ws.mutex.unlock(testing.io);
        try testing.expectEqualStrings(cache, ws.model.?.local_cache_root);
        for (ws.model.?.modules) |m| if (m.generated_root != null) break :blk try a.dupe(u8, m.root_file.?);
        return error.TestUnexpectedResult;
    };
    try testing.expect(std.mem.startsWith(u8, generated, cache));
    try testing.expectEqual(.generated, h.server.fileOrigin(try h.server.vfs.intern(generated)));

    // Open and save the generated options.zig: it is compiled only as a dependency of the project
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, generated, a, .limited(1024 * 1024));
    const uri = try open(&h, generated, text);
    try waitIdle(&h);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
    try waitIdle(&h);
    try expectNoErrors(&h, uri);
    // The definitions in it are generated by maker and cannot be renamed
    const offset = std.mem.indexOf(u8, text, "answer").?;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    const position = .{ .line = std.mem.count(u8, text[0..offset], "\n"), .character = offset - line_start + 1 };
    try testing.expect((try h.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = uri }, .position = position })).object.get("error") != null);
    try shutdown(&h);
    for (try progressTitles(&h)) |title| try testing.expect(!std.mem.startsWith(u8, title, "Compiling"));
}

/// Project for the configuration tests: with `-Dbad=true` the masked error in main.zig appears;
/// the `unit` step compiles t.zig (which has an error)
const settings_project: []const fixture.File = &.{
    .{ .path = "build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const opts = b.addOptions();
    \\    opts.addOption(bool, "bad", b.option(bool, "bad", "inject an error") orelse false);
    \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "build_options", .module = opts.createModule() }},
    \\    }) });
    \\    b.step("check", "Check").dependOn(&exe.step);
    \\    const tests = b.addTest(.{ .root_module = b.createModule(.{
    \\        .root_source_file = b.path("t.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.step("unit", "Unit tests").dependOn(&tests.step);
    \\}
    \\
    },
    .{ .path = "main.zig", .text =
    \\const o = @import("build_options");
    \\pub fn main() void {
    \\    if (o.bad) {
    \\        const x: u32 = "s";
    \\        _ = x;
    \\    }
    \\}
    \\
    },
    .{ .path = "t.zig", .text = "test {\n    const y: u8 = \"t\";\n    _ = y;\n}\n" },
};

test "settings: -D build args from initializationOptions, diagnostics.step change restarts the project" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();

    // 1. -Dbad=true: the branch is analyzed and reports an error (without the argument, o.bad is
    //    false and the branch is not analyzed)
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}}
    ));
    try waitIdle(&h);
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:23 zig: expected type 'u32'"});
    try testing.expect(diags.get("t.zig") == null);

    // 2. Switch to the unit step for diagnostics and drop the -D argument: the project restarts,
    //    main.zig's old diagnostics are cleared, and t.zig reports an error
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"zig-analyzer": {"diagnostics": {"step": "unit"}}}
    ) });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{});
    try expectDiagnostics(diags, "t.zig", &.{"1:18 zig: expected type 'u8'"});
    try shutdown(&h);
}

test "settings: pulled with workspace/configuration at startup and on change notifications without content" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    h.configuration = try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}}
    );
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .workspace = .{
        .configuration = true,
        .didChangeConfiguration = .{ .dynamicRegistration = true },
    } } });
    try h.notify("initialized", Empty{});
    try waitIdle(&h);
    // Build arguments pulled before startup take effect
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:23 zig: expected type 'u32'"});

    // The configuration change notification carries no content: the server pulls again
    h.configuration = try jsonValue(&h,
        \\{"diagnostics": {"step": "unit"}}
    );
    try h.notify("workspace/didChangeConfiguration", .{ .settings = null });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{});
    try expectDiagnostics(diags, "t.zig", &.{"1:18 zig: expected type 'u8'"});
    try shutdown(&h);

    try testing.expectEqual(1, countRequests(&h, "client/registerCapability"));
    try testing.expectEqual(2, countRequests(&h, "workspace/configuration"));
}

test "few CPU cores: async tasks run inline, waitIdle, progress and pulled settings still work" {
    // Simulate machines with few cores, such as CI: every `async` runs synchronously on the
    // caller's thread
    const old_limit = testing.io_instance.async_limit;
    testing.io_instance.setAsyncLimit(.nothing);
    defer testing.io_instance.setAsyncLimit(old_limit);

    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    h.configuration = try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}}
    );
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{
        .window = .{ .workDoneProgress = true },
        .workspace = .{ .configuration = true },
    } });
    try h.notify("initialized", Empty{});
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"3:23 zig: expected type 'u32'"});

    // Pulled again after the configuration change; waitIdle waits until the project restarts and
    // the build finishes
    h.configuration = try jsonValue(&h,
        \\{"diagnostics": {"step": "unit"}}
    );
    try h.notify("workspace/didChangeConfiguration", .{ .settings = null });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "t.zig", &.{"1:18 zig: expected type 'u8'"});
    try shutdown(&h);

    // The main loop is not blocked: the response to create is handled before the build ends, and
    // progress is sent normally
    var builds: usize = 0;
    for (try progressTitles(&h)) |t| {
        if (std.mem.startsWith(u8, t, "zig build")) builds += 1;
    }
    try testing.expect(builds >= 2);
}

/// Writes zigw, a script wrapping the user's zig, into the project directory: `zig env` reports
/// a different version, and other commands run as usual. Returns the initialization options that
/// use it.
fn mismatchedZig(h: *Harness, project: *fixture.Project) !std.json.Value {
    const zig = project.env.zig_exe;
    const script = try std.fmt.allocPrint(h.arena.allocator(),
        \\#!/bin/sh
        \\if [ "$1" = env ]; then "{s}" env | sed 's/\.version = "[^"]*"/.version = "0.0.0-mismatch"/'; else exec "{s}" "$@"; fi
        \\
    , .{ zig, zig });
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });
    return jsonValue(h, try std.fmt.allocPrint(h.arena.allocator(), "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{project.root}));
}

test "zig version mismatch: no build system is started, live diagnostics run zig ast-check outside the read transaction" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, true, try mismatchedZig(&h, &project));
    const lib_path = try project.path(h.arena.allocator(), "src/lib.zig");
    const lib_uri = try open(&h, lib_path, fixture.basic[2].text);
    try waitIdle(&h);

    // The build system is not started: there is no loading progress that never ends, and no
    // compiler diagnostics
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try expectProgressEnded(&h);
    // The message states both versions and the affected features
    const messages = try shownMessages(&h);
    const expected_head = "zig 0.0.0-mismatch differs from zig " ++ @import("builtin").zig_version_string ++ " that zig-analyzer was built with.";
    try testing.expect(anyContains(messages, expected_head));
    try testing.expect(anyContains(messages, "imports of named modules (dependencies, build options) are not resolved"));
    // Live diagnostics come from a zig ast-check child process, obtained outside the read
    // transaction
    {
        var ctx = h.server.db.beginRead(testing.allocator);
        defer ctx.end();
        try testing.expect(try ctx.get(live.LiveBackend, {}) == .subprocess);
    }
    const hits = h.server.live_prepared.hits;
    const edited = "pub fn hello() void {\n    var unused = 1;\n    var other = 2;\n}\n";
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = lib_uri, .version = 2 }, .contentChanges = &.{.{ .text = edited }} });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "lib.zig", &.{ "2:8 zig ast-check: unused local variable", "1:8 zig ast-check: unused local variable" });
    try testing.expect(h.server.live_prepared.hits > hits);
    try shutdown(&h);
}

test "zig version mismatch: files under a newly created build.zig drop their single-file compile results" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const main_text = "const geo = @import(\"geo\");\npub fn main() void {\n    _ = geo.name;\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initializeWith(&h, project.root, false, try mismatchedZig(&h, &project));
    _ = try open(&h, try project.path(a, "main.zig"), main_text);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"zig: no module named 'geo'"});

    // Create build.zig: the versions differ, so the project is not started, main.zig is no longer
    // compiled as a single file, and the earlier results are invalidated
    const build_path = try project.path(a, "build.zig");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = simple_build });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = try za.base.uri.fromPath(a, build_path), .type = 1 }} });
    try waitIdle(&h);
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{});
    try shutdown(&h);
}

test "unreadable build graph: loading ends, the build system is stopped and the user is told" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    // A fake maker: sends a build graph pointing to a nonexistent file, then waits for input
    // forever. `zig env` reports the wrapper script itself as zig; other commands run as usual.
    const a = testing.allocator;
    {
        const missing = "missing-configuration";
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeStruct(std.zig.Server.Message.Header{ .tag = .bsp_configuration, .bytes_len = missing.len }, .little);
        try w.writeAll(missing);
        try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "configuration.bin", .data = w.buffered() });
    }
    const zig = project.env.zig_exe;
    const script = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\case "$1" in
        \\env) "{s}" env | sed 's|\.zig_exe = "[^"]*"|.zig_exe = "{s}/zigw"|' ;;
        \\build) cat "{s}/configuration.bin"; exec cat >/dev/null ;;
        \\*) exec "{s}" "$@" ;;
        \\esac
        \\
    , .{ zig, project.root, project.root, zig });
    defer a.free(script);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const options = try std.fmt.allocPrint(h.arena.allocator(), "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{project.root});
    try initializeWith(&h, project.root, true, try jsonValue(&h, options));
    try waitIdle(&h);

    try expectProgressEnded(&h);
    try testing.expect(anyContains(try shownMessages(&h), "cannot read the build graph"));
    // maker is terminated: the background task cleans up after reading the end of input
    const ws = h.server.workspaces.items[0];
    for (0..100) |_| {
        ws.mutex.lockUncancelable(testing.io);
        const running = ws.client != null;
        ws.mutex.unlock(testing.io);
        if (!running) break;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    } else return error.TestUnexpectedResult;
    try shutdown(&h);
}

/// Every progress that was begun has ended
fn expectProgressEnded(h: *Harness) !void {
    var begins: usize = 0;
    var ends: usize = 0;
    for (try h.notifications("$/progress")) |m| {
        const kind = m.object.get("params").?.object.get("value").?.object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "begin")) begins += 1;
        if (std.mem.eql(u8, kind, "end")) ends += 1;
    }
    try testing.expectEqual(begins, ends);
}

/// Message texts of the window/showMessage notifications received
fn shownMessages(h: *Harness) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try h.notifications("window/showMessage")) |m| try out.append(h.arena.allocator(), m.object.get("params").?.object.get("message").?.string);
    return out.items;
}

fn anyContains(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| if (std.mem.indexOf(u8, s, needle) != null) return true;
    return false;
}

test "settings: several diagnostics steps are merged, unknown steps and settings are reported" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}, "diagnostics": {"steps": ["check", "unit", "nope"]}, "colors": {}, "inlay_hints": {"types": "yes"}}
    ));
    try waitIdle(&h);
    const diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:23 zig: expected type 'u32'"});
    try expectDiagnostics(diags, "t.zig", &.{"1:18 zig: expected type 'u8'"});
    const messages = try shownMessages(&h);
    try testing.expect(anyContains(messages, "some diagnostics.steps are not steps of"));
    try testing.expect(anyContains(messages, "unknown setting `colors`"));
    try testing.expect(anyContains(messages, "invalid value for `inlay_hints.types`, using the default"));
    try shutdown(&h);
}

test "settings: diagnostics.compiler off publishes no compiler diagnostics" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}, "diagnostics": {"compiler": false}}
    ));
    _ = try open(&h, try project.path(h.arena.allocator(), "main.zig"), settings_project[1].text);
    try waitIdle(&h);
    const diags = try h.diagnostics();
    for (diags.get("main.zig") orelse &.{}) |d| try testing.expect(std.mem.indexOf(u8, d, "zig:") == null);
    try testing.expect(diags.get("t.zig") == null);
    try shutdown(&h);
}

test "settings: build.enable can be switched off and on at runtime" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"build": {"enable": false, "args": ["-Dbad=true"]}}
    ));
    try waitIdle(&h);
    // The build system is not started
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try testing.expect((try h.diagnostics()).get("main.zig") == null);
    const std_path = try std.fs.path.join(h.arena.allocator(), &.{ project.env.std_dir, "std.zig" });
    const std_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, std_path, h.arena.allocator(), .limited(2 * 1024 * 1024));
    const std_uri = try open(&h, std_path, std_text);
    try waitIdle(&h);
    try expectNoErrors(&h, std_uri);

    // Enable: the project is started and compiler diagnostics are published
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"build": {"enable": true, "args": ["-Dbad=true"]}}
    ) });
    try waitIdle(&h);
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"3:23 zig: expected type 'u32'"});
    try expectNoErrors(&h, std_uri);

    // Disable again: the project stops and its diagnostics are cleared
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"build": {"enable": false}}
    ) });
    try waitIdle(&h);
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{});
    try expectNoErrors(&h, std_uri);
    try shutdown(&h);
}

test "project zig-analyzer.zon: build settings apply, a change on disk restarts the project" {
    var project = try fixture.Project.create(settings_project ++ [_]fixture.File{
        .{ .path = "zig-analyzer.zon", .text =
        \\// Build settings of the project
        \\.{
        \\    .build = .{ .args = .{"-Dbad=true"} },
        \\    .log = .{ .level = .err },
        \\}
        },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:23 zig: expected type 'u32'"});
    try testing.expect(anyContains(try shownMessages(&h), "`log.level` cannot be set in zig-analyzer.zon"));

    // Outside the editor, switch to the unit step for diagnostics and drop the -D argument:
    // the project restarts
    const a = h.arena.allocator();
    const path = try project.path(a, "zig-analyzer.zon");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = ".{ .diagnostics = .{ .steps = .{\"unit\"} } }" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = try za.base.uri.fromPath(a, path), .type = 2 }} });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{});
    try expectDiagnostics(diags, "t.zig", &.{"1:18 zig: expected type 'u8'"});
    try shutdown(&h);
}

/// Settings converted to JSON (characters in paths are escaped as in JSON)
fn settingsValue(h: *Harness, settings: anytype) !std.json.Value {
    return jsonValue(h, try std.json.Stringify.valueAlloc(h.arena.allocator(), settings, .{}));
}

/// Root file of the standard library in the module graph
fn stdRoot(h: *Harness) ![]const u8 {
    return (try h.request("zig-analyzer/moduleGraph", {})).object.get("result").?.object.get("std_root").?.string;
}

/// Requests goto definition at the start of `needle` in `text` and returns the path of the target
/// file
fn definitionPath(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    const offset = std.mem.indexOf(u8, text, needle).?;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    const resp = try h.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = .{
        .line = std.mem.count(u8, text[0..offset], "\n"),
        .character = offset - line_start,
    } });
    const result = resp.object.get("result").?;
    if (result != .object) return error.TestUnexpectedResult;
    return za.base.uri.toPath(h.arena.allocator(), result.object.get("uri").?.string);
}

/// zig commands recorded by the wrapper script (except `zig env`): each line is
/// "<subcommand> <ZIG_LIB_DIR>"
fn zigCalls(h: *Harness, path: []const u8) ![]const []const u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, h.arena.allocator(), .limited(1024 * 1024));
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "env ")) continue;
        try out.append(h.arena.allocator(), line);
    }
    return out.items;
}

fn hasLine(lines: []const []const u8, line: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, l, line)) return true;
    return false;
}

const lib_path_main =
    \\const std = @import("std");
    \\pub fn main() void {
    \\    const x: u32 = "s";
    \\    _ = x;
    \\    _ = std.mem.Allocator;
    \\}
    \\
;

test "settings: zig.lib_path: std resolves under it and zig runs with it, removing it reloads std, restarts the project and recompiles standalone files" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = simple_build },
        .{ .path = "main.zig", .text = lib_path_main },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    // Outside the workspace: another path pointing to the lib directory of the user's zig, and a
    // standalone file compiled in single-file mode
    var other = testing.tmpDir(.{});
    defer other.cleanup();
    try other.dir.symLink(testing.io, project.env.lib_dir, "zig-lib", .{ .is_directory = true });
    try other.dir.writeFile(testing.io, .{ .sub_path = "solo.zig", .data = lib_path_main });
    const other_root = try other.dir.realPathFileAlloc(testing.io, ".", a);
    const lib = try std.fs.path.join(a, &.{ other_root, "zig-lib" });
    // Script zigw wrapping the user's zig: records the subcommand and ZIG_LIB_DIR of each command;
    // `zig env` reports the script itself as zig, and other commands run as usual
    const zig = project.env.zig_exe;
    const calls = try project.path(a, "zig-calls");
    const zigw = try project.path(a, "zigw");
    const script = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\echo "$1 $ZIG_LIB_DIR" >> "{s}"
        \\case "$1" in
        \\env) "{s}" env | sed 's|\.zig_exe = "[^"]*"|.zig_exe = "{s}"|' ;;
        \\*) exec "{s}" "$@" ;;
        \\esac
        \\
    , .{ calls, zig, zigw, zig });
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });

    try initializeWith(&h, project.root, false, try settingsValue(&h, .{ .zig = .{ .path = zigw, .lib_path = lib } }));
    const main_uri = try open(&h, try project.path(a, "main.zig"), lib_path_main);
    _ = try open(&h, try std.fs.path.join(a, &.{ other_root, "solo.zig" }), lib_path_main);
    try waitIdle(&h);
    const lib_std = try std.fs.path.join(a, &.{ lib, "std" });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ lib_std, "std.zig" }), try stdRoot(&h));
    const lib_mem = try std.fs.path.join(a, &.{ lib_std, "mem.zig" });
    try testing.expectEqualStrings(lib_mem, try definitionPath(&h, main_uri, lib_path_main, "Allocator"));
    const status = (try h.request("zig-analyzer/fileStatus", .{ .textDocument = .{ .uri = try za.base.uri.fromPath(a, lib_mem) } })).object.get("result").?.object;
    try testing.expectEqualStrings("zig_lib", status.get("origin").?.string);
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"2:19 zig: expected type 'u32'"});
    try expectDiagnostics(diags, "solo.zig", &.{"2:19 zig: expected type 'u32'"});
    // The project build, single-file compiles and other zig child processes all use the overriding
    // lib directory (when the cache has no record of the default builtin.zig, the command
    // generating it runs before the build)
    const before = try zigCalls(&h, calls);
    try testing.expect(hasLine(before, try std.fmt.allocPrint(a, "build {s}", .{lib})));
    try testing.expect(hasLine(before, try std.fmt.allocPrint(a, "build-obj {s}", .{lib})));
    for (before) |line| try testing.expect(std.mem.endsWith(u8, line, lib));

    // Remove the override: the standard library is reloaded, the project restarts with the lib
    // directory reported by `zig env`, and standalone files are recompiled
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .zig = .{ .path = zigw } } });
    try waitIdle(&h);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ project.env.std_dir, "std.zig" }), try stdRoot(&h));
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ project.env.std_dir, "mem.zig" }), try definitionPath(&h, main_uri, lib_path_main, "Allocator"));
    const after = (try zigCalls(&h, calls))[before.len..];
    try testing.expect(hasLine(after, "build ") and hasLine(after, "build-obj "));
    for (after) |line| try testing.expect(std.mem.endsWith(u8, line, " "));
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"2:19 zig: expected type 'u32'"});
    try expectDiagnostics(diags, "solo.zig", &.{"2:19 zig: expected type 'u32'"});
    try shutdown(&h);
}

const builtin_main = "const builtin = @import(\"builtin\");\npub const mode = builtin.mode;\n";

test "settings: invalid zig paths fall back to zig env with a message, zig.builtin_path applies to standalone files" {
    var project = try fixture.Project.create(&.{
        .{ .path = "one.zig", .text = builtin_main },
        .{ .path = "target/builtin.zig", .text = "pub const mode = .ReleaseFast;\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    // A lib directory without std/std.zig, and a nonexistent cache directory and builtin.zig
    const missing = try project.path(a, "missing");
    try initializeWith(&h, project.root, false, try settingsValue(&h, .{ .zig = .{
        .lib_path = project.root,
        .global_cache_path = missing,
        .builtin_path = missing,
    } }));
    const uri = try open(&h, try project.path(a, "one.zig"), builtin_main);
    try waitIdle(&h);
    const messages = try shownMessages(&h);
    try testing.expect(anyContains(messages, try std.fmt.allocPrint(a, "zig.lib_path {s} does not contain std/std.zig, using {s}", .{ project.root, project.env.lib_dir })));
    try testing.expect(anyContains(messages, try std.fmt.allocPrint(a, "zig.global_cache_path {s} is not an existing directory, using {s}", .{ missing, project.env.global_cache_dir })));
    try testing.expect(anyContains(messages, try std.fmt.allocPrint(a, "zig.builtin_path {s} is not an existing file, using the generated builtin.zig", .{missing})));
    // Paths from the server are normalized (on Windows, `\` separators and an uppercase drive
    // letter), so the expected paths are normalized the same way before comparing
    try testing.expectEqualStrings(try std.fs.path.resolveAlloc(a, &.{ project.env.std_dir, "std.zig" }), try stdRoot(&h));
    try testing.expectEqualStrings(project.env.global_cache_dir, h.server.zigEnv().?.global_cache_dir);
    const generated = try definitionPath(&h, uri, builtin_main, "mode;");
    try testing.expect(std.mem.startsWith(u8, generated, try std.fs.path.resolveAlloc(a, &.{project.env.global_cache_dir})));

    // Switch to an existing builtin.zig: files outside any project use it
    const custom = try std.fs.path.resolveAlloc(a, &.{ project.root, "target", "builtin.zig" });
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .zig = .{ .builtin_path = custom } } });
    try waitIdle(&h);
    try testing.expectEqualStrings(custom, try definitionPath(&h, uri, builtin_main, "mode;"));
    // Remove the override: back to the generated builtin.zig
    try h.notify("workspace/didChangeConfiguration", .{ .settings = Empty{} });
    try waitIdle(&h);
    try testing.expectEqualStrings(generated, try definitionPath(&h, uri, builtin_main, "mode;"));
    try testing.expectEqual(messages.len, (try shownMessages(&h)).len);
    try shutdown(&h);
}

/// The diagnostics last published for a document, and how many times it was published
fn lastPublished(h: *Harness, document_uri: []const u8) !struct { diagnostics: []const std.json.Value, count: usize } {
    var last: ?[]const std.json.Value = null;
    var count: usize = 0;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, document_uri)) continue;
        last = params.get("diagnostics").?.array.items;
        count += 1;
    }
    return .{ .diagnostics = last orelse return error.NotPublished, .count = count };
}

/// "uri-basename line:character message" of each relatedInformation entry of a diagnostic
fn relatedLocations(h: *Harness, diagnostic: std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const related = diagnostic.object.get("relatedInformation") orelse return out.items;
    for (related.array.items) |r| {
        const location = r.object.get("location").?.object;
        const file_uri = location.get("uri").?.string;
        const start = location.get("range").?.object.get("start").?.object;
        try out.append(h.arena.allocator(), try std.fmt.allocPrint(h.arena.allocator(), "{s} {d}:{d} {s}", .{
            file_uri[std.mem.lastIndexOfScalar(u8, file_uri, '/').? + 1 ..],
            start.get("line").?.integer,
            start.get("character").?.integer,
            r.object.get("message").?.string,
        }));
    }
    return out.items;
}

test "notes into another open file follow its unsaved edits and its close" {
    const util_text = "pub fn helper(x: u32) u32 {\n    return x;\n}\n";
    const main_text = "const util = @import(\"util.zig\");\nexport fn f() u32 {\n    return util.helper(1, 2);\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "util.zig", .text = util_text },
        .{ .path = "main.zig", .text = main_text },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"diagnostics": {"debounce_ms": 0}}
    ));
    try waitIdle(&h);
    const util_uri = try open(&h, try project.path(a, "util.zig"), util_text);
    const main_uri = try open(&h, try project.path(a, "main.zig"), main_text);
    try waitIdle(&h);
    const declared = "util.zig 0:0 function declared here";
    {
        const diags = (try lastPublished(&h, main_uri)).diagnostics;
        try testing.expectEqual(1, diags.len);
        try testing.expectEqualStrings(declared, (try relatedLocations(&h, diags[0]))[0]);
    }

    // Unsaved lines inserted above the function: the note moves with them. Guards against keeping
    // main.zig's note on the old line until main.zig itself is republished.
    const published = (try lastPublished(&h, main_uri)).count;
    try change(&h, util_uri, 2, "// one\n// two\n// three\n" ++ util_text);
    try waitIdle(&h);
    {
        const last = try lastPublished(&h, main_uri);
        try testing.expect(last.count > published);
        try testing.expectEqualStrings("util.zig 3:0 function declared here", (try relatedLocations(&h, last.diagnostics[0]))[0]);
    }

    // Closed without saving: back to the text on disk
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = util_uri } });
    try waitIdle(&h);
    try testing.expectEqualStrings(declared, (try relatedLocations(&h, (try lastPublished(&h, main_uri)).diagnostics[0]))[0]);
    try shutdown(&h);
}

/// Start positions ("line:character") of the inactive code hints last published for a document
fn inactiveHints(h: *Harness, document_uri: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ((try lastPublished(h, document_uri)).diagnostics) |d| {
        if (std.mem.indexOf(u8, d.object.get("message").?.string, "inactive") == null) continue;
        const start = d.object.get("range").?.object.get("start").?.object;
        try out.append(h.arena.allocator(), try std.fmt.allocPrint(h.arena.allocator(), "{d}:{d}", .{ start.get("line").?.integer, start.get("character").?.integer }));
    }
    return out.items;
}

test "inactive code hints of other open files follow the comptime values they read" {
    const consts_text = "pub const N: usize = 4;\npub const wide = N > 3;\n";
    const narrow_text = "pub const N: usize = 4;\npub const wide = N > 5;\n";
    const shapes_text = "const consts = @import(\"consts.zig\");\npub const Coord = if (consts.wide) f64 else f32;\n";
    const main_text = "const shapes = @import(\"shapes.zig\");\nexport fn entry() void {\n    const c: shapes.Coord = 1.5;\n    _ = c;\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "consts.zig", .text = consts_text },
        .{ .path = "shapes.zig", .text = shapes_text },
        .{ .path = "main.zig", .text = main_text },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"diagnostics": {"compiler": false, "inactive_code": true, "debounce_ms": 0}}
    ));
    try waitIdle(&h);
    const consts_path = try project.path(a, "consts.zig");
    const consts_uri = try open(&h, consts_path, consts_text);
    _ = try open(&h, try project.path(a, "main.zig"), main_text);
    const shapes_uri = try open(&h, try project.path(a, "shapes.zig"), shapes_text);
    try waitIdle(&h);
    const f32_hint = "1:44";
    const f64_hint = "1:35";
    try testing.expectEqualStrings(f32_hint, (try inactiveHints(&h, shapes_uri))[0]);

    // An unsaved edit flips the condition. Guards against keeping the hint of the old value in
    // the other open file.
    try change(&h, consts_uri, 2, narrow_text);
    try waitIdle(&h);
    try testing.expectEqualStrings(f64_hint, (try inactiveHints(&h, shapes_uri))[0]);

    // Closed without saving, then changed on disk while closed
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = consts_uri } });
    try waitIdle(&h);
    try testing.expectEqualStrings(f32_hint, (try inactiveHints(&h, shapes_uri))[0]);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = consts_path, .data = narrow_text });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = consts_uri, .type = 2 }} });
    try waitIdle(&h);
    try testing.expectEqualStrings(f64_hint, (try inactiveHints(&h, shapes_uri))[0]);
    try shutdown(&h);
}

test "inlay hint refresh after changes the client cannot see: other documents, disk, module graph" {
    const dep_text = "pub fn make(width: u32, height: u32) u32 {\n    return width * height;\n}\n";
    const extra_text = "pub const scale: u32 = 2;\n";
    const main_text = "const dep = @import(\"dep.zig\");\nconst extra = @import(\"extra.zig\");\npub fn main() void {\n    _ = dep.make(1, extra.scale);\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "dep.zig", .text = dep_text },
        .{ .path = "extra.zig", .text = extra_text },
        .{ .path = "main.zig", .text = main_text },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, project.root),
        .capabilities = .{ .workspace = .{ .inlayHint = .{ .refreshSupport = true } } },
        .initializationOptions = try jsonValue(&h,
            \\{"diagnostics": {"debounce_ms": 0}}
        ),
    });
    try h.notify("initialized", Empty{});
    // A single document: its hints may have been pulled before the standard library and the
    // module graph were loaded. Guards against asking only for semantic tokens again.
    _ = try open(&h, try project.path(a, "main.zig"), main_text);
    try waitIdle(&h);
    var before = countRequests(&h, "workspace/inlayHint/refresh");
    try testing.expect(before > 0);

    // Another document is edited
    const dep_uri = try open(&h, try project.path(a, "dep.zig"), dep_text);
    try waitIdle(&h);
    before = countRequests(&h, "workspace/inlayHint/refresh");
    try change(&h, dep_uri, 2, "pub fn make(w2: u32, h2: u32) u32 {\n    return w2 * h2;\n}\n");
    try waitIdle(&h);
    try testing.expect(countRequests(&h, "workspace/inlayHint/refresh") > before);
    before = countRequests(&h, "workspace/inlayHint/refresh");

    const extra_path = try project.path(a, "extra.zig");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = extra_path, .data = "pub const scale: u32 = 3;\n" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = try za.base.uri.fromPath(a, extra_path), .type = 2 }} });
    try waitIdle(&h);
    try testing.expect(countRequests(&h, "workspace/inlayHint/refresh") > before);
    try shutdown(&h);
}
