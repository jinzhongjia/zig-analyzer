//! Origin of a file: the Zig installation, generated files, fetched dependency packages, or user
//! code. Libraries in the compile context, durability, and the scopes of rename, server-side
//! watching, and workspace symbol are all derived from this one classification (for the rules it
//! is based on, see `Server.originRules`).

const std = @import("std");
const Vfs = @import("../base/Vfs.zig");
const Durability = @import("../db/engine.zig").Durability;
const isVirtual = @import("Server.zig").isVirtual;

pub const Origin = enum {
    /// Documents not on disk (`untitled:`, etc.)
    virtual,
    /// The Zig installation: the standard library, `lib/compiler`, etc. Under a workspace root too,
    /// unless it is Zig's own source tree (see `Rules.zig_source_tree`)
    zig_lib,
    /// Generated files: the global cache and the local caches used by each project's maker
    generated,
    /// Fetched dependency packages
    package,
    /// User code: under a workspace root (excluding `.zig-cache` and `zig-pkg` in it), or outside
    /// the roots but in a module of some project (modules added by path, packages specified with
    /// `--fork`)
    user,
    /// User code outside the workspace roots that no project contains (a file opened without a
    /// workspace folder, or from outside the folders): which other files use it is not known
    outside,
    /// Other files: in `.zig-cache` or `zig-pkg` under a root (stale copies), or outside the roots
    /// and projects while the location of the Zig installation is unknown (its files cannot be
    /// told apart)
    other,

    /// Library: the contents are not edited by the user
    pub fn isLibrary(o: Origin) bool {
        return switch (o) {
            .zig_lib, .generated, .package => true,
            .virtual, .user, .outside, .other => false,
        };
    }

    /// How often the file contents change: the Zig installation and fetched dependency packages
    /// (addressed by hash) do not change, generated files are updated with builds, and everything
    /// else changes often
    pub fn durability(o: Origin) Durability {
        return switch (o) {
            .zig_lib, .package => .high,
            .generated => .medium,
            .virtual, .user, .outside, .other => .low,
        };
    }
};

/// Rules for the classification. The strings are owned by the creator.
pub const Rules = struct {
    /// lib_dir and global_cache_dir from `zig env`; null when the zig environment is unknown
    zig_lib: ?[]const u8 = null,
    global_cache: ?[]const u8 = null,
    /// `zig_lib` is the `lib` directory of Zig's own source tree: its parent directory has a
    /// build.zig. Under a root, the installation is then Zig itself being developed, user code;
    /// otherwise it stays the installation (a root such as a package manager's prefix contains it)
    zig_source_tree: bool = false,
    /// Workspace root directories
    roots: []const []const u8 = &.{},
    /// Local cache directories used by each project's maker (one that contains the build root is
    /// left out, since generated files could not be told apart from project files)
    local_caches: []const []const u8 = &.{},
    /// Root directories of the dependency packages fetched by each project
    packages: []const []const u8 = &.{},
};

/// Origin of `path`; `in_project` means the file is in some project's module graph, and only
/// affects files outside the roots. Checked in order: dependency packages, generated files (even
/// under a root), user code under a root, the Zig installation (under a root too, unless it is
/// Zig's own source tree, see `Rules.zig_source_tree`), project modules, and then the user's files
/// outside the workspace. A root inside the Zig installation (such as its `std` directory opened
/// as a workspace folder) does not make the installation user code.
pub fn classify(vfs: *Vfs, rules: Rules, path: []const u8, in_project: bool) Origin {
    if (isVirtual(path)) return .virtual;
    for (rules.packages) |p| if (vfs.isUnder(path, p)) return .package;
    for (rules.local_caches) |c| if (vfs.isUnder(path, c)) return .generated;
    if (rules.global_cache) |c| if (vfs.isUnder(path, c)) return .generated;
    var in_root = false;
    roots: for (rules.roots) |root| {
        if (path.len <= root.len or !vfs.isUnder(path, root)) continue;
        if (rules.zig_lib) |l| if (vfs.isUnder(root, l)) continue;
        if (rules.zig_lib) |l| if (!rules.zig_source_tree and vfs.isUnder(path, l)) continue;
        in_root = true;
        const rest = path[root.len..];
        const sub = if (std.fs.path.isSep(rest[0])) rest[1..] else rest;
        // The default local cache and package directories of maker: when others are used
        // instead (`--cache-dir`, `--pkg-dir`), the ones here are stale copies. Only these exact
        // directory names count (`zig-pkgs` is an ordinary directory)
        var end: usize = 0;
        while (end < sub.len and !std.fs.path.isSep(sub[end])) end += 1;
        if (end < sub.len) for ([_][]const u8{ ".zig-cache", "zig-pkg" }) |name| {
            const same = std.mem.eql(u8, sub[0..end], name) or
                (std.ascii.eqlIgnoreCase(sub[0..end], name) and vfs.caseOf(root) == .insensitive);
            if (same) continue :roots;
        };
        return .user;
    }
    if (rules.zig_lib) |l| if (vfs.isUnder(path, l)) return .zig_lib;
    if (in_root) return .other;
    if (in_project) return .user;
    return if (rules.zig_lib != null) .outside else .other;
}

const testing = std.testing;
const native = @import("../util/test_path.zig").native;

test classify {
    var vfs: Vfs = .init(testing.io, testing.allocator);
    defer vfs.deinit();
    const rules: Rules = .{
        .zig_lib = native("/zig/lib"),
        .global_cache = native("/home/.cache/zig"),
        .roots = &.{native("/ws")},
        .local_caches = &.{ native("/ws/.zig-cache"), native("/elsewhere/cache") },
        .packages = &.{ native("/ws/zig-pkg/foo-1.0.0-hash"), native("/pkgs/bar-hash") },
    };
    const Case = struct { []const u8, bool, Origin };
    const cases = [_]Case{
        .{ native("/zig/lib/std/std.zig"), true, .zig_lib },
        .{ native("/home/.cache/zig/b/builtin.zig"), false, .generated },
        .{ native("/ws/.zig-cache/c/options.zig"), true, .generated },
        .{ native("/elsewhere/cache/c/options.zig"), true, .generated },
        .{ native("/ws/zig-pkg/foo-1.0.0-hash/src/root.zig"), true, .package },
        .{ native("/pkgs/bar-hash/src/root.zig"), true, .package },
        .{ native("/ws/src/main.zig"), true, .user },
        // Files under a root that are not in the module graph are user code too
        .{ native("/ws/scripts/gen.zig"), false, .user },
        // Stale copy left under the root after switching to a package directory elsewhere
        .{ native("/ws/zig-pkg/stale-hash/src/root.zig"), true, .other },
        // Names that only start like those directories were taken for them, which refused renames
        .{ native("/ws/zig-pkgs/a.zig"), false, .user },
        .{ native("/ws/zig-pkg-b.zig"), false, .user },
        .{ native("/ws/.zig-cache-c/c.zig"), false, .user },
        // Module outside the root, added to the project by path
        .{ native("/libs/shared/src/root.zig"), true, .user },
        // Outside the roots and in no project: the user's file, opened from outside the folders
        .{ native("/tmp/scratch.zig"), false, .outside },
    };
    for (cases) |c| {
        testing.expectEqual(c[2], classify(&vfs, rules, c[0], c[1])) catch |err| {
            std.debug.print("classify {s}\n", .{c[0]});
            return err;
        };
    }
    // The lib directory of Zig's own source tree under a workspace root: Zig itself is being
    // developed
    const in_root: Rules = .{ .zig_lib = native("/ws/lib"), .zig_source_tree = true, .roots = &.{native("/ws")} };
    try testing.expectEqual(.user, classify(&vfs, in_root, native("/ws/lib/std/std.zig"), true));
    try testing.expectEqual(.user, classify(&vfs, in_root, native("/ws/src/Sema.zig"), true));
    // A Zig installation under a root that is not its source tree, such as a package manager's
    // prefix (a git repository, which editors take as the root): it was compiled alone as user code
    const prefix: Rules = .{ .zig_lib = native("/opt/brew/Cellar/zig/lib/zig"), .roots = &.{native("/opt/brew")} };
    try testing.expectEqual(.zig_lib, classify(&vfs, prefix, native("/opt/brew/Cellar/zig/lib/zig/std/Build.zig"), false));
    try testing.expectEqual(.zig_lib, classify(&vfs, prefix, native("/opt/brew/Cellar/zig/lib/zig/std/Build.zig"), true));
    try testing.expectEqual(.user, classify(&vfs, prefix, native("/opt/brew/Cellar/zig/notes.zig"), false));
    // A workspace root inside the Zig installation: renaming there would edit the installation
    const inside: Rules = .{ .zig_lib = native("/zig/lib"), .roots = &.{ native("/proj"), native("/zig/lib/std") } };
    try testing.expectEqual(.zig_lib, classify(&vfs, inside, native("/zig/lib/std/mem.zig"), false));
    try testing.expectEqual(.user, classify(&vfs, inside, native("/proj/main.zig"), false));
    // Unknown zig environment: files outside the roots and projects cannot be told apart from the
    // installation
    try testing.expectEqual(.other, classify(&vfs, .{}, native("/zig/lib/std/std.zig"), false));
    try testing.expectEqual(.other, classify(&vfs, .{}, native("/tmp/scratch.zig"), false));
}

test "durability follows the origin" {
    try testing.expectEqual(.high, Origin.zig_lib.durability());
    try testing.expectEqual(.high, Origin.package.durability());
    try testing.expectEqual(.medium, Origin.generated.durability());
    try testing.expectEqual(.low, Origin.user.durability());
    try testing.expectEqual(.low, Origin.other.durability());
}
