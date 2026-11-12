//! The user's source files under the workspace root directories. Find references, rename, the
//! fixes that edit references, and workspace symbol search them besides the module graph: files
//! that are not in any build graph still import and use the declarations (single-file mode, build
//! scripts and their helpers, examples outside the build graph).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Vfs = @import("../base/Vfs.zig");
const origin = @import("origin.zig");

/// A Zig source or ZON file name
pub fn isSource(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon");
}

/// Directories that hold no source code of the workspace: hidden directories (`.zig-cache`,
/// `.git`), fetched packages (`zig-pkg`) and the install prefix (`zig-out`)
fn skipped(name: []const u8) bool {
    return name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "zig-out");
}

/// What `scan` found, allocated in its arena
pub const Found = struct {
    /// Paths of the source files whose origin is user code (see `origin.classify`)
    files: []const []const u8,
    /// The directories entered, roots included, each once: a source file created in any of them,
    /// or in a directory created in any of them, is one of the files a later scan finds (see
    /// `entersDir`)
    dirs: []const []const u8,
};

/// The source files under `rules.roots` whose origin is user code, and the directories entered.
/// Directories are walked without following symbolic links to directories; skipped directories
/// (see `skipped`) and the local caches and package directories in `rules` are not entered, and a
/// directory under several roots is walked once.
pub fn scan(io: Io, arena: Allocator, vfs: *Vfs, rules: origin.Rules) Allocator.Error!Found {
    var out: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    for (rules.roots) |root| try stack.append(arena, root);
    while (stack.pop()) |dir_path| {
        const key = if (vfs.caseOf(dir_path) == .insensitive) try std.ascii.allocLowerString(arena, dir_path) else dir_path;
        if ((try visited.getOrPut(arena, key)).found_existing) continue;
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        try dirs.append(arena, dir_path);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| switch (entry.kind) {
            .directory => {
                if (skipped(entry.name)) continue;
                const sub = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                if (isLibraryDir(vfs, rules, sub)) continue;
                try stack.append(arena, sub);
            },
            .file, .sym_link => {
                if (!isSource(entry.name)) continue;
                const path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                if (origin.classify(vfs, rules, path, false) == .user) try out.append(arena, path);
            },
            else => {},
        };
    }
    return .{ .files = out.items, .dirs = dirs.items };
}

/// Whether `path` is one of the files `scan` finds (when it exists): a source file under a root,
/// reached from that root without entering a skipped or library directory, whose origin is user
/// code
pub fn contains(vfs: *Vfs, rules: origin.Rules, path: []const u8) bool {
    if (!isSource(std.fs.path.basename(path))) return false;
    if (origin.classify(vfs, rules, path, false) != .user) return false;
    const dir = std.fs.path.dirname(path) orelse return false;
    for (rules.roots) |root| {
        if (vfs.isUnder(path, root) and enters(vfs, rules, root, dir)) return true;
    }
    return false;
}

/// Whether a directory created or removed at `dir` may change what `scan` finds: `scan` enters it,
/// or it is a root or contains one. A directory that `scan` does not enter (such as those a build
/// creates in `.zig-cache` and `zig-out`) holds none of the files it finds.
pub fn affectsScan(vfs: *Vfs, rules: origin.Rules, dir: []const u8) bool {
    for (rules.roots) |root| {
        if (vfs.isUnder(root, dir)) return true;
        if (vfs.isUnder(dir, root) and enters(vfs, rules, root, dir)) return true;
    }
    return false;
}

/// Whether walking `root` enters `dir`, a directory under it: no directory below `root` on the way
/// to `dir`, `dir` included, is skipped or a library directory
fn enters(vfs: *Vfs, rules: origin.Rules, root: []const u8, dir: []const u8) bool {
    var d: ?[]const u8 = dir;
    while (d) |p| : (d = std.fs.path.dirname(p)) {
        if (p.len <= root.len) return true;
        if (skipped(std.fs.path.basename(p)) or isLibraryDir(vfs, rules, p)) return false;
    }
    return true;
}

/// `dir` is or lies in a local cache, a fetched package, the global cache, or the Zig installation
/// (unless it is Zig's own source tree, see `origin.Rules.zig_source_tree`)
fn isLibraryDir(vfs: *Vfs, rules: origin.Rules, dir: []const u8) bool {
    for (rules.local_caches) |c| if (vfs.isUnder(dir, c)) return true;
    for (rules.packages) |p| if (vfs.isUnder(dir, p)) return true;
    if (rules.global_cache) |c| if (vfs.isUnder(dir, c)) return true;
    if (rules.zig_lib) |l| if (!rules.zig_source_tree and vfs.isUnder(dir, l)) return true;
    return false;
}

const testing = std.testing;

test scan {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{
        "ws/zig-pkgs/a.zig",
        "ws/main.zig",
        "ws/build.zig",
        "ws/build.zig.zon",
        "ws/notes.txt",
        "ws/src/lib.zig",
        "ws/src/data.zon",
        "ws/examples/demo.zig",
        "ws/.zig-cache/o/x.zig",
        "ws/.git/hook.zig",
        "ws/zig-pkg/dep-hash/root.zig",
        "ws/zig-out/share/copy.zig",
        "ws/cache/c/gen.zig",
        "ws/vendor/pkg/root.zig",
        "ws/nested/inner.zig",
        "ws/.hidden/proj/app.zig",
    }) |sub| {
        if (std.fs.path.dirname(sub)) |d| try tmp.dir.createDirPath(testing.io, d);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = "" });
    }
    try tmp.dir.createDirPath(testing.io, "ws/empty/inner");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(base);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var vfs: Vfs = .init(testing.io, testing.allocator);
    defer vfs.deinit();
    const ws = try std.fs.path.join(a, &.{ base, "ws" });
    const rules: origin.Rules = .{
        // A root inside another root is walked once; one inside a skipped directory is walked
        .roots = &.{ ws, try std.fs.path.join(a, &.{ ws, "nested" }), try std.fs.path.join(a, &.{ ws, ".hidden", "proj" }) },
        .local_caches = &.{try std.fs.path.join(a, &.{ ws, "cache" })},
        .packages = &.{try std.fs.path.join(a, &.{ ws, "vendor", "pkg" })},
    };
    const found = try scan(testing.io, a, &vfs, rules);
    var names: std.ArrayList([]const u8) = .empty;
    for (found.files) |p| try names.append(a, p[ws.len + 1 ..]);
    const lt = struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt;
    std.mem.sort([]const u8, names.items, {}, lt);
    const sep = std.fs.path.sep_str;
    const expected = [_][]const u8{
        ".hidden" ++ sep ++ "proj" ++ sep ++ "app.zig",
        "build.zig",
        "build.zig.zon",
        "examples" ++ sep ++ "demo.zig",
        "main.zig",
        "nested" ++ sep ++ "inner.zig",
        "src" ++ sep ++ "data.zon",
        "src" ++ sep ++ "lib.zig",
        "zig-pkgs" ++ sep ++ "a.zig",
    };
    try testing.expectEqual(expected.len, names.items.len);
    for (expected, names.items) |e, n| try testing.expectEqualStrings(e, n);
    // `contains` agrees with `scan`, also for files that do not exist yet
    for (found.files) |p| try testing.expect(contains(&vfs, rules, p));
    for ([_][]const u8{ "new.zig", "src" ++ sep ++ "new.zon", ".hidden" ++ sep ++ "proj" ++ sep ++ "new.zig" }) |sub| {
        try testing.expect(contains(&vfs, rules, try std.fs.path.join(a, &.{ ws, sub })));
    }
    for ([_][]const u8{
        "notes.txt",
        ".zig-cache" ++ sep ++ "o" ++ sep ++ "y.zig",
        "zig-out" ++ sep ++ "new.zig",
        "zig-pkg" ++ sep ++ "x" ++ sep ++ "new.zig",
        "cache" ++ sep ++ "new.zig",
        "vendor" ++ sep ++ "pkg" ++ sep ++ "new.zig",
        ".hidden" ++ sep ++ "other.zig",
    }) |sub| {
        try testing.expect(!contains(&vfs, rules, try std.fs.path.join(a, &.{ ws, sub })));
    }
    try testing.expect(!contains(&vfs, rules, try std.fs.path.join(a, &.{ base, "outside.zig" })));
    // A directory created or removed changes what `scan` finds when `scan` enters it, or when it is
    // a root or contains one
    for ([_][]const u8{
        "src",
        "src" ++ sep ++ "new",
        "examples",
        "nested",
        "vendor",
        ".hidden",
        ".hidden" ++ sep ++ "proj",
        ".hidden" ++ sep ++ "proj" ++ sep ++ "sub",
    }) |sub| {
        try testing.expect(affectsScan(&vfs, rules, try std.fs.path.join(a, &.{ ws, sub })));
    }
    try testing.expect(affectsScan(&vfs, rules, ws));
    try testing.expect(affectsScan(&vfs, rules, base));
    // What a build leaves behind, version control, packages and caches: `scan` enters none of them
    for ([_][]const u8{
        ".zig-cache",
        ".zig-cache" ++ sep ++ "o" ++ sep ++ "0123",
        ".git" ++ sep ++ "objects",
        "zig-out",
        "zig-out" ++ sep ++ "bin",
        "zig-pkg" ++ sep ++ "dep-hash",
        "cache",
        "cache" ++ sep ++ "c",
        "vendor" ++ sep ++ "pkg",
        ".hidden" ++ sep ++ "other",
    }) |sub| {
        try testing.expect(!affectsScan(&vfs, rules, try std.fs.path.join(a, &.{ ws, sub })));
    }
    try testing.expect(!affectsScan(&vfs, rules, try std.fs.path.join(a, &.{ base, "outside" })));

    // The directories entered, empty ones included
    var dirs: std.ArrayList([]const u8) = .empty;
    for (found.dirs) |d| try dirs.append(a, if (d.len == ws.len) "" else d[ws.len + 1 ..]);
    std.mem.sort([]const u8, dirs.items, {}, lt);
    const expected_dirs = [_][]const u8{
        "",
        ".hidden" ++ sep ++ "proj",
        "empty",
        "empty" ++ sep ++ "inner",
        "examples",
        "nested",
        "src",
        "vendor",
        "zig-pkgs",
    };
    try testing.expectEqual(expected_dirs.len, dirs.items.len);
    for (expected_dirs, dirs.items) |e, d| try testing.expectEqualStrings(e, d);
    for (found.dirs) |d| try testing.expect(affectsScan(&vfs, rules, d));
}

test "scan: a Zig installation under a root is skipped unless it is Zig's own source tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "ws/main.zig", "ws/Cellar/zig/lib/zig/std/std.zig", "ws/Cellar/zig/lib/zig/std/Build.zig" }) |sub| {
        try tmp.dir.createDirPath(testing.io, std.fs.path.dirname(sub).?);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = "" });
    }
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(base);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var vfs: Vfs = .init(testing.io, testing.allocator);
    defer vfs.deinit();
    const ws = try std.fs.path.join(a, &.{ base, "ws" });
    const lib = try std.fs.path.join(a, &.{ ws, "Cellar", "zig", "lib", "zig" });
    const build_zig = try std.fs.path.join(a, &.{ lib, "std", "Build.zig" });
    // A package manager's prefix as the root: the installation in it is not workspace code
    const prefix: origin.Rules = .{ .zig_lib = lib, .roots = &.{ws} };
    const found = try scan(testing.io, a, &vfs, prefix);
    try testing.expectEqual(1, found.files.len);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ ws, "main.zig" }), found.files[0]);
    try testing.expect(!contains(&vfs, prefix, build_zig));
    try testing.expect(!affectsScan(&vfs, prefix, try std.fs.path.join(a, &.{ lib, "std" })));
    // Zig's own source tree: its lib directory is developed in the workspace
    const source_tree: origin.Rules = .{ .zig_lib = lib, .zig_source_tree = true, .roots = &.{ws} };
    try testing.expectEqual(3, (try scan(testing.io, a, &vfs, source_tree)).files.len);
    try testing.expect(contains(&vfs, source_tree, build_zig));
}
