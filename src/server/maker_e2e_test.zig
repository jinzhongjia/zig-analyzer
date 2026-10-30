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
