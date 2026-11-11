//! The packages whose build.zig is compiled into a project's configure program: the project
//! itself and, through the `.dependencies` of each `build.zig.zon`, every dependency package that
//! has a build.zig. The maker gives each build.zig module the build.zig modules of its package's
//! dependencies, by the names `build.zig.zon` gives them (`@import("dep")` in build.zig), so
//! editing such a build.zig changes the configuration.
//!
//! A dependency given by `.path` is relative to the package that declares it; one given by
//! `.hash` lies in `<package directory>/<hash>` (`--pkg-dir`, `--system`, `ZIG_LOCAL_PKG_DIR`, or
//! `<build root>/zig-pkg`, as the maker decides) once fetched. Dependencies that are not on disk
//! (lazy dependencies not fetched yet) and packages without a build.zig are left out, as the maker
//! does.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Zoir = std.zig.Zoir;

pub const Package = struct {
    /// Root directory (absolute path)
    root: []const u8,
    /// Dependencies with a build.zig, by the names this package's build.zig.zon gives them
    deps: []const Dep,
};

pub const Dep = struct {
    name: []const u8,
    /// Index into `Packages.list`
    package: u32,
};

pub const Packages = struct {
    arena: std.heap.ArenaAllocator.State,
    /// The project itself first
    list: []const Package,

    pub fn deinit(p: *Packages, gpa: Allocator) void {
        var arena = p.arena.promote(gpa);
        arena.deinit();
        p.* = undefined;
    }
};

/// The package directory the maker uses: `--pkg-dir` (or `ZIG_LOCAL_PKG_DIR`), then `--system`,
/// then `<build root>/zig-pkg`; a relative path is relative to the build root (the maker's cwd)
pub fn packageDir(a: Allocator, build_root: []const u8, build_args: []const []const u8, env_pkg_dir: ?[]const u8) Allocator.Error![]const u8 {
    var pkg_dir: ?[]const u8 = env_pkg_dir;
    var system: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < build_args.len) : (i += 1) {
        if (std.mem.eql(u8, build_args[i], "--pkg-dir")) {
            pkg_dir = build_args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, build_args[i], "--system")) {
            system = build_args[i + 1];
            i += 1;
        }
    }
    const dir = pkg_dir orelse system orelse return std.fs.path.join(a, &.{ build_root, "zig-pkg" });
    return std.fs.path.resolveAlloc(a, &.{ build_root, dir });
}

/// Finds the packages of the project in `build_root` (absolute, normalized), reading the
/// build.zig.zon files from disk
pub fn discover(gpa: Allocator, io: Io, build_root: []const u8, pkg_dir: []const u8) Allocator.Error!Packages {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    var roots: std.StringArrayHashMapUnmanaged(void) = .empty;
    var deps: std.ArrayList([]const Dep) = .empty;
    try roots.put(a, try a.dupe(u8, build_root), {});
    var i: usize = 0;
    while (i < roots.count()) : (i += 1) {
        const root = roots.keys()[i];
        var list: std.ArrayList(Dep) = .empty;
        const zon_path = try std.fs.path.join(a, &.{ root, "build.zig.zon" });
        const text = Io.Dir.cwd().readFileAllocOptions(io, zon_path, gpa, .limited(16 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (text) |t| {
            defer gpa.free(t);
            var it = try Dependencies.init(gpa, t);
            defer it.deinit(gpa);
            while (it.next()) |d| {
                const dep_root = if (d.path) |p|
                    try std.fs.path.resolveAlloc(a, &.{ root, p })
                else if (d.hash) |h|
                    try std.fs.path.join(a, &.{ pkg_dir, h })
                else
                    continue;
                const build_zig = try std.fs.path.join(a, &.{ dep_root, "build.zig" });
                Io.Dir.cwd().access(io, build_zig, .{}) catch continue;
                const gop = try roots.getOrPut(a, dep_root);
                try list.append(a, .{ .name = try a.dupe(u8, d.name), .package = @intCast(gop.index) });
            }
        }
        try deps.append(a, list.items);
    }
    const packages = try a.alloc(Package, roots.count());
    for (packages, roots.keys(), deps.items) |*p, root, d| p.* = .{ .root = root, .deps = d };
    return .{ .arena = arena_state.state, .list = packages };
}

/// The directories of the dependencies that the build.zig.zon text `text` of the package in
/// `package_root` gives by `.path`, resolved against `package_root` (allocated by `a`); nothing
/// when it does not parse. `gpa` holds the parse while it runs.
pub fn pathDependencies(a: Allocator, gpa: Allocator, package_root: []const u8, text: [:0]const u8) Allocator.Error![]const []const u8 {
    var it = try Dependencies.init(gpa, text);
    defer it.deinit(gpa);
    var out: std.ArrayList([]const u8) = .empty;
    while (it.next()) |d| if (d.path) |p| try out.append(a, try std.fs.path.resolveAlloc(a, &.{ package_root, p }));
    return out.items;
}

/// The entries of `.dependencies` in a build.zig.zon; nothing when it does not parse
const Dependencies = struct {
    ast: std.zig.Ast,
    zoir: Zoir,
    names: []const Zoir.NullTerminatedString = &.{},
    vals: Zoir.Node.Index.Range = .{ .start = .root, .len = 0 },
    next_index: u32 = 0,

    const Entry = struct { name: []const u8, path: ?[]const u8, hash: ?[]const u8 };

    fn init(gpa: Allocator, text: [:0]const u8) Allocator.Error!Dependencies {
        var ast = try std.zig.Ast.parse(gpa, text, .{ .mode = .zon });
        errdefer ast.deinit(gpa);
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
        var d: Dependencies = .{ .ast = ast, .zoir = zoir };
        if (ast.errors.len != 0 or zoir.hasCompileErrors()) return d;
        const top = switch (Zoir.Node.Index.root.get(&zoir)) {
            .struct_literal => |s| s,
            else => return d,
        };
        for (top.names, 0..) |n, i| {
            if (!std.mem.eql(u8, n.get(&zoir), "dependencies")) continue;
            switch (top.vals.at(@intCast(i)).get(&zoir)) {
                .struct_literal => |s| {
                    d.names = s.names;
                    d.vals = s.vals;
                },
                else => {},
            }
        }
        return d;
    }

    fn deinit(d: *Dependencies, gpa: Allocator) void {
        d.zoir.deinit(gpa);
        d.ast.deinit(gpa);
    }

    fn next(d: *Dependencies) ?Entry {
        while (d.next_index < d.names.len) {
            const i = d.next_index;
            d.next_index += 1;
            const fields = switch (d.vals.at(i).get(&d.zoir)) {
                .struct_literal => |s| s,
                else => continue,
            };
            var entry: Entry = .{ .name = d.names[i].get(&d.zoir), .path = null, .hash = null };
            for (fields.names, 0..) |n, j| {
                const value = switch (fields.vals.at(@intCast(j)).get(&d.zoir)) {
                    .string_literal => |s| s,
                    else => continue,
                };
                const field = n.get(&d.zoir);
                if (std.mem.eql(u8, field, "path")) entry.path = value;
                if (std.mem.eql(u8, field, "hash")) entry.hash = value;
            }
            return entry;
        }
        return null;
    }
};

const testing = std.testing;

test discover {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "app/build.zig", "" },
        .{
            "app/build.zig.zon",
            \\.{
            \\    .name = .app,
            \\    .dependencies = .{
            \\        .helper = .{ .path = "../helper" },
            \\        .@"fetched-dep" = .{ .url = "https://example.com/x.tar.gz", .hash = "x-0.0.0-AAAA" },
            \\        .lazy = .{ .url = "https://example.com/y.tar.gz", .hash = "y-0.0.0-BBBB", .lazy = true },
            \\        .nobuild = .{ .path = "nobuild" },
            \\    },
            \\}
        },
        .{ "helper/build.zig", "" },
        .{ "helper/build.zig.zon", ".{ .name = .helper, .dependencies = .{ .shared = .{ .path = \"../app/zig-pkg/x-0.0.0-AAAA\" } } }" },
        .{ "app/zig-pkg/x-0.0.0-AAAA/build.zig", "" },
        .{ "app/nobuild/a.zig", "" },
    };
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(testing.io, d);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
    }
    const gpa = testing.allocator;
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(base);
    const app = try std.fs.path.join(gpa, &.{ base, "app" });
    defer gpa.free(app);
    const pkg_dir = try packageDir(gpa, app, &.{}, null);
    defer gpa.free(pkg_dir);
    var p = try discover(gpa, testing.io, app, pkg_dir);
    defer p.deinit(gpa);

    try testing.expectEqual(3, p.list.len);
    try testing.expectEqualStrings(app, p.list[0].root);
    try testing.expectEqual(2, p.list[0].deps.len);
    try testing.expectEqualStrings("helper", p.list[0].deps[0].name);
    try testing.expectEqualStrings("helper", std.fs.path.basename(p.list[p.list[0].deps[0].package].root));
    try testing.expectEqualStrings("fetched-dep", p.list[0].deps[1].name);
    const fetched = p.list[0].deps[1].package;
    try testing.expectEqualStrings("x-0.0.0-AAAA", std.fs.path.basename(p.list[fetched].root));
    // The same package reached through another path is one package
    const helper = p.list[p.list[0].deps[0].package];
    try testing.expectEqual(1, helper.deps.len);
    try testing.expectEqual(fetched, helper.deps[0].package);
}

test packageDir {
    const native = @import("../util/test_path.zig").native;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = native("/p");
    try testing.expectEqualStrings(native("/p/zig-pkg"), try packageDir(a, root, &.{"-Doptimize=Debug"}, null));
    try testing.expectEqualStrings(native("/p/pkgs"), try packageDir(a, root, &.{}, "pkgs"));
    try testing.expectEqualStrings(native("/sys"), try packageDir(a, root, &.{ "--system", native("/sys") }, null));
    try testing.expectEqualStrings(native("/q"), try packageDir(a, root, &.{ "--system", native("/sys"), "--pkg-dir", "../q" }, null));
}

test pathDependencies {
    const native = @import("../util/test_path.zig").native;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = native("/repo/examples/hello");
    const deps = try pathDependencies(a, testing.allocator, root,
        \\.{
        \\    .name = .hello,
        \\    .dependencies = .{
        \\        .lib = .{ .path = "../../" },
        \\        .fetched = .{ .url = "https://example.com/x.tar.gz", .hash = "x-0.0.0-AAAA" },
        \\        .sibling = .{ .path = "../todo" },
        \\    },
        \\}
    );
    try testing.expectEqual(2, deps.len);
    try testing.expectEqualStrings(native("/repo"), deps[0]);
    try testing.expectEqualStrings(native("/repo/examples/todo"), deps[1]);
    // A build.zig.zon that does not parse gives nothing
    try testing.expectEqual(0, (try pathDependencies(a, testing.allocator, root, ".{ .dependencies = .{ .lib = .{ .path = \"..\" }")).len);
    try testing.expectEqual(0, (try pathDependencies(a, testing.allocator, root, ".{ .name = .hello }")).len);
}
