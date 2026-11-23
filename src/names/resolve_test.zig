const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const Db = database.Db;
const FileText = database.inputs.FileText;
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;
const ModuleGraph = @import("ModuleGraph.zig");
const resolve = @import("resolve.zig");
const definition = @import("../ide/definition.zig");
const completion = @import("../ide/completion.zig");
const search = @import("../ide_db/search.zig");
const test_path = @import("../util/test_path.zig");
const native = test_path.native;
const InternPool = @import("../sema/InternPool.zig");

/// In-memory project: file contents are set directly as inputs; the module graph is built by hand
pub const World = struct {
    vfs: Vfs,
    ip: InternPool,
    env: database.Env,
    db: Db,
    arena: std.heap.ArenaAllocator,
    /// builtin used by files that belong to no module when `setGraph` is called
    default_builtin: ?FileId = null,

    pub fn init(w: *World) !void {
        w.default_builtin = null;
        w.vfs = .init(testing.io, testing.allocator);
        w.ip = try .init(testing.allocator, testing.io);
        w.env = .{ .vfs = &w.vfs, .ip = &w.ip };
        w.db = .init(testing.io, testing.allocator, &w.env);
        w.arena = .init(testing.allocator);
    }

    pub fn deinit(w: *World) void {
        w.db.deinit();
        w.ip.deinit();
        w.vfs.deinit();
        w.arena.deinit();
    }

    /// Makes every live check fail to run (`live.Result.complete` is false): the subprocess
    /// backend with a zig that does not exist
    pub fn zigUnavailable(w: *World) !void {
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(database.live.LiveBackend, {}, .{ .subprocess = try testing.allocator.dupe(u8, "/nonexistent/zig") }, .low);
    }

    /// The added file and the cursor position after removing `<|>` (0 without a marker)
    pub const Added = struct { file: FileId, cursor: u32 };

    pub fn add(w: *World, comptime path: []const u8, text: []const u8) !Added {
        return w.addNative(native(path), text);
    }

    /// Like `add`, but `path` is already a native path
    pub fn addNative(w: *World, path: []const u8, text: []const u8) !Added {
        const file = try w.vfs.intern(path);
        const cursor = std.mem.indexOf(u8, text, "<|>");
        const clean = if (cursor) |c| try std.mem.concat(testing.allocator, u8, &.{ text[0..c], text[c + 3 ..] }) else try testing.allocator.dupe(u8, text);
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(FileText, file, clean, .low);
        return .{ .file = file, .cursor = @intCast(cursor orelse 0) };
    }

    /// `FileEntry.compile` refers to the compilation rooted at the module with the same index (the
    /// builtin of that module is the one its standard library uses, and its standard library is
    /// `std_root`); compilation 0 exists even without modules
    pub fn setGraph(w: *World, std_root: ?FileId, modules: []const ModuleGraph.Module, files: []const ModuleGraph.FileEntry) !void {
        const g = try testing.allocator.create(ModuleGraph);
        const sorted = try w.arena.allocator().dupe(ModuleGraph.FileEntry, files);
        std.mem.sort(ModuleGraph.FileEntry, sorted, {}, struct {
            fn lt(_: void, a: ModuleGraph.FileEntry, b: ModuleGraph.FileEntry) bool {
                return @backingInt(a.file) < @backingInt(b.file);
            }
        }.lt);
        const compiles = try w.arena.allocator().alloc(ModuleGraph.Compile, @max(modules.len, 1));
        for (compiles, 0..) |*c, i| c.* = if (i < modules.len) .{ .root = modules[i].root, .std_root = std_root, .builtin = modules[i].builtin } else .{ .root = null, .std_root = std_root };
        g.* = .{ .arena = .{}, .std_root = std_root, .modules = modules, .compiles = compiles, .files = sorted, .default_builtin = w.default_builtin };
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(ModuleGraph.Input, {}, g, .low);
    }

    /// Sets the user's source files under the workspace roots (`inputs.WorkspaceFiles`)
    pub fn setWorkspaceFiles(w: *World, files: []const FileId) !void {
        const sorted = try testing.allocator.dupe(FileId, files);
        std.mem.sort(FileId, sorted, {}, struct {
            fn lt(_: void, a: FileId, b: FileId) bool {
                return @backingInt(a) < @backingInt(b);
            }
        }.lt);
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(database.inputs.WorkspaceFiles, {}, sorted, .low);
    }

    /// The files in a `fixture` and the position of `<|>`
    pub const Fixture = struct {
        /// Paths as written in the fixture (posix style) and the corresponding files
        paths: []const []const u8,
        files: []const FileId,
        /// The file containing `<|>` and the position after the marker is removed
        cursor: ?struct { file: FileId, offset: u32 } = null,

        pub fn file(f: Fixture, path: []const u8) FileId {
            for (f.paths, f.files) |p, id| if (std.mem.eql(u8, p, path)) return id;
            std.debug.panic("fixture has no file {s}", .{path});
        }
    };

    /// A multi-file, multi-module test project (modeled on rust-analyzer's fixtures). Each file
    /// starts with a line `//- <path> <attribute>...`, with the path in posix style. The attributes
    /// determine the file's place in the module graph; files without attributes are not in the
    /// module graph:
    /// - `std`: a file in the standard library; the `std.zig` among them is its root;
    /// - `module:<name>`: the root of this module; the `deps:<name>[=<module>],...` right after it
    ///   lists the imports of this module (`=<module>` is omitted when the import name equals the
    ///   module name); a line can have several `module:`s, i.e. the same root file belongs to
    ///   several modules;
    /// - `in:<module>`: belongs to this module.
    /// Modules are numbered in declaration order; for a file in several modules, the one written
    /// first takes priority. A module's `@import("root")` points to the first module in declaration
    /// order that can reach it through imports and is not imported by any other module.
    pub fn fixture(w: *World, text: []const u8) !Fixture {
        const a = w.arena.allocator();
        const Block = struct { path: []const u8, attrs: []const u8, body: std.ArrayList(u8) = .empty };
        var blocks: std.ArrayList(Block) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "//- ")) {
                const spec = std.mem.trim(u8, line[4..], " ");
                const space = std.mem.indexOfScalar(u8, spec, ' ') orelse spec.len;
                try blocks.append(a, .{ .path = spec[0..space], .attrs = spec[space..] });
                continue;
            }
            if (blocks.items.len == 0) return error.FixtureTextBeforeFirstFile;
            const body = &blocks.items[blocks.items.len - 1].body;
            try body.appendSlice(a, line);
            try body.append(a, '\n');
        }

        var out: Fixture = .{ .paths = &.{}, .files = &.{} };
        const paths = try a.alloc([]const u8, blocks.items.len);
        const ids = try a.alloc(FileId, blocks.items.len);
        for (blocks.items, paths, ids) |b, *p, *id| {
            const added = try w.addNative(try test_path.nativeAlloc(a, b.path), b.body.items);
            p.* = b.path;
            id.* = added.file;
            if (std.mem.indexOf(u8, b.body.items, "<|>") != null) out.cursor = .{ .file = added.file, .offset = added.cursor };
        }
        out.paths = paths;
        out.files = ids;

        // Modules are numbered in declaration order
        const Decl = struct { name: []const u8, root: FileId, deps: []const u8 = "" };
        var decls: std.ArrayList(Decl) = .empty;
        for (blocks.items, ids) |b, id| {
            var it = std.mem.tokenizeScalar(u8, b.attrs, ' ');
            while (it.next()) |attr| {
                if (std.mem.startsWith(u8, attr, "module:")) {
                    try decls.append(a, .{ .name = attr["module:".len..], .root = id });
                } else if (std.mem.startsWith(u8, attr, "deps:")) {
                    if (decls.items.len == 0) return error.FixtureDepsWithoutModule;
                    decls.items[decls.items.len - 1].deps = attr["deps:".len..];
                }
            }
        }
        const Index = struct {
            fn of(ds: []const Decl, name: []const u8) !u32 {
                for (ds, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return @intCast(i);
                return error.FixtureUnknownModule;
            }
        };
        const modules = try a.alloc(ModuleGraph.Module, decls.items.len);
        for (decls.items, modules) |d, *m| {
            var imports: std.ArrayList(ModuleGraph.Import) = .empty;
            var deps = std.mem.tokenizeScalar(u8, d.deps, ',');
            while (deps.next()) |dep| {
                const eq = std.mem.indexOfScalar(u8, dep, '=');
                const target = if (eq) |e| dep[e + 1 ..] else dep;
                try imports.append(a, .{ .name = if (eq) |e| dep[0..e] else dep, .module = try Index.of(decls.items, target) });
            }
            m.* = .{ .root = d.root, .imports = imports.items };
        }

        // The root module of each module: traverse from the modules that are not imported, in
        // declaration order; the first to reach a module wins
        const imported = try a.alloc(bool, modules.len);
        @memset(imported, false);
        for (modules) |m| for (m.imports) |imp| {
            imported[imp.module] = true;
        };
        const root_of = try a.alloc(u32, modules.len);
        @memset(root_of, 0);
        const reached = try a.alloc(bool, modules.len);
        @memset(reached, false);
        for (0..modules.len) |r| {
            if (imported[r]) continue;
            var queue: std.ArrayList(u32) = .empty;
            try queue.append(a, @intCast(r));
            var i: usize = 0;
            while (i < queue.items.len) : (i += 1) {
                const m = queue.items[i];
                if (reached[m]) continue;
                reached[m] = true;
                root_of[m] = @intCast(r);
                for (modules[m].imports) |imp| try queue.append(a, imp.module);
            }
        }

        var entries: std.ArrayList(ModuleGraph.FileEntry) = .empty;
        var std_root: ?FileId = null;
        for (blocks.items, ids) |b, id| {
            var in: std.ArrayList(u32) = .empty;
            var is_std = false;
            var it = std.mem.tokenizeScalar(u8, b.attrs, ' ');
            while (it.next()) |attr| {
                if (std.mem.eql(u8, attr, "std")) {
                    is_std = true;
                } else if (std.mem.startsWith(u8, attr, "module:")) {
                    try in.append(a, try Index.of(decls.items, attr["module:".len..]));
                } else if (std.mem.startsWith(u8, attr, "in:")) {
                    try in.append(a, try Index.of(decls.items, attr["in:".len..]));
                } else if (!std.mem.startsWith(u8, attr, "deps:")) return error.FixtureUnknownAttribute;
            }
            if (is_std) {
                try entries.append(a, .{ .file = id, .module = ModuleGraph.std_module, .compile = 0 });
                if (std.mem.endsWith(u8, b.path, "/std.zig")) std_root = id;
            } else if (in.items.len != 0) {
                try entries.append(a, .{ .file = id, .module = in.items[0], .compile = root_of[in.items[0]], .others = in.items[1..] });
            }
        }
        try w.setGraph(std_root, modules, entries.items);
        return out;
    }

    /// Sets the target-dependent parameters for value operations (as the Server does when it
    /// updates the module graph)
    pub fn setTarget(w: *World, t: InternPool.Target) !void {
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(database.sema.TargetAbi, {}, t, .medium);
        w.ip.setTarget(t);
    }

    /// Result of goto definition: "file name:target text"
    fn goto(w: *World, file: FileId, offset: u32) ![]const u8 {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
        const t = try definition.definition(&r, file, offset) orelse return "null";
        return w.targetLabel(&ctx, t);
    }

    /// Result of `definition.definitionTargets` / `declarationTargets`: "file name:target text" of
    /// each target, joined with spaces
    fn gotoAll(w: *World, file: FileId, offset: u32, comptime find: anytype) ![]const u8 {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
        var labels: std.ArrayList([]const u8) = .empty;
        for (try find(&r, file, offset)) |t| try labels.append(w.arena.allocator(), try w.targetLabel(&ctx, t));
        return std.mem.join(w.arena.allocator(), " ", labels.items);
    }

    fn targetLabel(w: *World, ctx: *Db.Ctx, t: definition.Target) ![]const u8 {
        const text = (try ctx.get(database.syntax.SourceText, t.file)).text;
        return std.fmt.allocPrint(w.arena.allocator(), "{s}:{s}", .{ std.fs.path.basename(w.vfs.path(t.file)), text[t.start..t.end] });
    }

    /// Completion labels other than keywords, sorted alphabetically and joined with spaces
    fn complete(w: *World, file: FileId, offset: u32) ![]const u8 {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
        const items = (try completion.complete(&r, file, offset, .{ .auto_import = false })).items;
        var list: std.ArrayList([]const u8) = .empty;
        for (items) |it| if (switch (it.kind) {
            .keyword, .primitive_type, .primitive_value, .postfix => false,
            else => true,
        }) try list.append(w.arena.allocator(), it.label);
        const labels = list.items;
        std.mem.sort([]const u8, labels, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return std.mem.join(w.arena.allocator(), " ", labels);
    }
};

test "fixture builds the module graph from file attributes" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:exe deps:dep=a module:test deps:dep=b
        \\const dep = @import("dep");<|>
        \\//- /p/a.zig module:a
        \\//- /p/b.zig module:b
        \\//- /p/b_util.zig in:b
        \\//- /p/notes.zig
        \\//- /zig/std/std.zig std
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    const g = (try ctx.get(ModuleGraph.Input, {})).?;
    try testing.expectEqual(f.file("/zig/std/std.zig"), g.std_root.?);
    try testing.expectEqual(4, g.modules.len);
    try testing.expectEqual(f.file("/p/main.zig"), g.modules[1].root.?);
    try testing.expectEqualStrings("dep", g.modules[1].imports[0].name);
    try testing.expectEqual(3, g.modules[1].imports[0].module);
    try testing.expectEqual(f.file("/p/main.zig"), f.cursor.?.file);
    try testing.expectEqual(std.mem.indexOf(u8, "const dep = @import(\"dep\");", ";").? + 1, f.cursor.?.offset);
    // The module written first takes priority; the test module imports b and is its root
    const Expect = struct { path: []const u8, module: u32, root: u32, others: []const u32 = &.{} };
    for ([_]Expect{
        .{ .path = "/p/main.zig", .module = 0, .root = 0, .others = &.{1} },
        .{ .path = "/p/a.zig", .module = 2, .root = 0 },
        .{ .path = "/p/b.zig", .module = 3, .root = 1 },
        .{ .path = "/p/b_util.zig", .module = 3, .root = 1 },
        .{ .path = "/zig/std/std.zig", .module = ModuleGraph.std_module, .root = 0 },
    }) |e| {
        const entry = for (g.files) |x| {
            if (x.file == f.file(e.path)) break x;
        } else return error.TestUnexpectedResult;
        try testing.expectEqual(e.module, entry.module);
        try testing.expectEqual(e.root, entry.compile);
        try testing.expectEqualSlices(u32, e.others, entry.others);
    }
    // Files without attributes are not in the module graph
    for (g.files) |x| try testing.expect(x.file != f.file("/p/notes.zig"));
}

test "locals, params and container declarations" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\const limit = 10;
        \\fn helper() void {}
        \\pub fn run(n: u32) u32 {
        \\    const total = n + limit;
        \\    helper();
        \\    return total<|>;
        \\}
    ;
    const f = try w.add("/p/main.zig", src);
    const text = (try std.mem.concat(w.arena.allocator(), u8, &.{ src[0..f.cursor], src[f.cursor + 3 ..] }));
    const at = struct {
        fn of(t: []const u8, needle: []const u8, nth: usize) u32 {
            var start: usize = 0;
            for (0..nth) |_| start = std.mem.indexOfPos(u8, t, start, needle).? + 1;
            return @intCast(std.mem.indexOfPos(u8, t, start, needle).?);
        }
    }.of;
    try testing.expectEqualStrings("main.zig:total", try w.goto(f.file, f.cursor));
    try testing.expectEqualStrings("main.zig:n", try w.goto(f.file, at(text, "n + limit", 0)));
    try testing.expectEqualStrings("main.zig:limit", try w.goto(f.file, at(text, "limit;", 0) + 1));
    try testing.expectEqualStrings("main.zig:helper", try w.goto(f.file, at(text, "helper();", 0)));
    // Cursor at the end of the name
    try testing.expectEqualStrings("main.zig:total", try w.goto(f.file, f.cursor));
    // The declaration itself
    try testing.expectEqualStrings("main.zig:run", try w.goto(f.file, at(text, "run", 0)));
    // Primitive types have no definition
    try testing.expectEqualStrings("null", try w.goto(f.file, at(text, "u32", 0)));

    try testing.expectEqualStrings("helper limit n run total", try w.complete(f.file, f.cursor));
}

test "imports: relative files, modules, std and root" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\const std = @import("std");
        \\const lib = @import("lib");
        \\const util = @import("util.zig");
        \\const root = @import("root");
        \\const A = std.mem.Allocator;
        \\pub fn main() void {
        \\    _ = lib.Point.origin();
        \\    util.helper();
        \\    _ = A.alloc;
        \\    _ = root.main;
        \\    std.mem.<|>
        \\}
    ;
    const f = try w.fixture("//- /p/src/main.zig module:main deps:lib\n" ++ src ++ "\n" ++
        \\//- /p/lib/lib.zig module:lib
        \\pub const Point = struct { x: i32, pub fn origin() Point {} };
        \\//- /p/src/util.zig
        \\pub fn helper() void {}
        \\//- /zig/std/std.zig std
        \\pub const mem = @import("mem.zig");
        \\const hidden = 1;
        \\//- /zig/std/mem.zig std
        \\pub const Allocator = @import("mem/Allocator.zig");
        \\pub fn eql() bool {}
        \\fn private() void {}
        \\//- /zig/std/mem/Allocator.zig
        \\ptr: *anyopaque,
        \\pub fn alloc() void {}
    );
    const main: struct { file: FileId, cursor: u32 } = .{ .file = f.file("/p/src/main.zig"), .cursor = f.cursor.?.offset };
    const text = try std.mem.replaceOwned(u8, w.arena.allocator(), src, "<|>", "");
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    try testing.expectEqualStrings("lib.zig:Point", try w.goto(main.file, at(text, "Point.origin")));
    try testing.expectEqualStrings("lib.zig:origin", try w.goto(main.file, at(text, "origin()")));
    try testing.expectEqualStrings("util.zig:helper", try w.goto(main.file, at(text, "helper()")));
    // `pub const Allocator = @import("mem/Allocator.zig")`: definition goes to the file
    try testing.expectEqualStrings("Allocator.zig:", try w.goto(main.file, at(text, "Allocator;")));
    try testing.expectEqualStrings("Allocator.zig:alloc", try w.goto(main.file, at(text, "alloc;")));
    try testing.expectEqualStrings("main.zig:main", try w.goto(main.file, at(text, "main;")));
    // An import string jumps to the start of the file
    try testing.expectEqualStrings("util.zig:", try w.goto(main.file, at(text, "util.zig") + 1));
    try testing.expectEqualStrings("std.zig:", try w.goto(main.file, at(text, "\"std\"")));
    // Only pub declarations are listed for other files
    try testing.expectEqualStrings("Allocator eql", try w.complete(main.file, main.cursor));
}

test "relative imports may not leave the module root" {
    // The compiler reports `import of file outside module path`: `/p/other.zig` is not part of
    // the module rooted at `/p/src/main.zig`, so the import stays unknown.
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/src/main.zig module:app
        \\const util = @import("util.zig");
        \\pub fn main() void {
        \\    util.run();
        \\}
        \\//- /p/src/util.zig in:app
        \\const other = @import("../other.zig");
        \\pub fn run() void {
        \\    other.thing<|>;
        \\}
        \\//- /p/other.zig
        \\pub const thing = 1;
    );
    const util = f.file("/p/src/util.zig");
    try testing.expectEqualStrings("null", try w.goto(util, f.cursor.?.offset));
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    try testing.expectEqual(@as(?FileId, null), try r.resolveImport(util, "../other.zig"));
}

test "relative imports inside the module root resolve" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/src/main.zig module:app
        \\pub const value = 1;
        \\//- /p/src/a/util.zig in:app
        \\const main = @import("../main.zig");
        \\pub const value = main.value<|>;
    );
    const util = f.file("/p/src/a/util.zig");
    try testing.expectEqualStrings("main.zig:value", try w.goto(util, f.cursor.?.offset));
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    try testing.expectEqual(@as(?FileId, f.file("/p/src/main.zig")), try r.resolveImport(util, "../main.zig"));
}

test "relative imports of a file outside the module graph resolve" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/src/main.zig module:app
        \\//- /p/loose.zig
        \\const sibling = @import("sibling.zig");
        \\pub const value = sibling.value<|>;
        \\//- /p/sibling.zig
        \\pub const value = 1;
    );
    const loose = f.file("/p/loose.zig");
    try testing.expectEqualStrings("sibling.zig:value", try w.goto(loose, f.cursor.?.offset));
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    try testing.expectEqual(@as(?FileId, f.file("/p/sibling.zig")), try r.resolveImport(loose, "sibling.zig"));
}

test "imports of a file in several modules" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\const dep = @import("dep");
        \\pub fn main() void {
        \\    _ = dep.fromA();
        \\}
        \\test {
        \\    const h = @import("helper");
        \\    _ = h.fromB();
        \\    _ = @import("<|>");
        \\}
    ;
    // The exe module and the test module share the root file: in exe, dep → a; in test, dep → b,
    // plus helper → b
    const f = try w.fixture("//- /p/src/main.zig module:exe deps:dep=a module:test deps:dep=b,helper=b\n" ++ src ++ "\n" ++
        \\//- /p/a.zig module:a
        \\pub fn fromA() u32 {}
        \\//- /p/b.zig module:b
        \\pub fn fromB() u32 {}
    );
    const main: struct { file: FileId, cursor: u32 } = .{ .file = f.file("/p/src/main.zig"), .cursor = f.cursor.?.offset };
    const text = try std.mem.replaceOwned(u8, w.arena.allocator(), src, "<|>", "");
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    // A name imported only by the test module
    try testing.expectEqualStrings("b.zig:", try w.goto(main.file, at(text, "\"helper\"")));
    try testing.expectEqualStrings("b.zig:fromB", try w.goto(main.file, at(text, "fromB")));
    // A name imported by both modules resolves to the one in the preferred module
    try testing.expectEqualStrings("a.zig:fromA", try w.goto(main.file, at(text, "fromA")));
    try testing.expectEqualStrings("builtin dep helper root std", try w.complete(main.file, main.cursor));
}

test "goto on a module import that differs between the modules of a file lists every target" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const exe_cfg = try w.add("/p/exe_cfg.zig", "pub const mode = 1;\n");
    const test_cfg = try w.add("/p/test_cfg.zig", "pub const mode = 2;\n");
    const util = try w.add("/p/util.zig", "pub fn helper() void {}\n");
    _ = try w.add("/p/src/local.zig", "pub fn run() void {}\n");
    const src =
        \\const cfg = @import("cfg");
        \\const util = @import("util");
        \\const local = @import("local.zig");
        \\pub fn main() void {
        \\    _ = cfg.mode;
        \\    util.helper();
        \\    local.run();
        \\}
    ;
    const main = try w.add("/p/src/main.zig", src);
    // The exe module (0) and the test module (1) share the root file: the targets of cfg differ,
    // those of util are the same
    try w.setGraph(null, &.{
        .{ .root = main.file, .imports = &.{ .{ .name = "cfg", .module = 2 }, .{ .name = "util", .module = 4 } } },
        .{ .root = main.file, .imports = &.{ .{ .name = "cfg", .module = 3 }, .{ .name = "util", .module = 4 } } },
        .{ .root = exe_cfg.file, .imports = &.{} },
        .{ .root = test_cfg.file, .imports = &.{} },
        .{ .root = util.file, .imports = &.{} },
    }, &.{
        .{ .file = main.file, .module = 0, .compile = 0, .others = &.{1} },
        .{ .file = exe_cfg.file, .module = 2, .compile = 0 },
        .{ .file = test_cfg.file, .module = 3, .compile = 1 },
        .{ .file = util.file, .module = 4, .compile = 0 },
    });
    const at = struct {
        fn of(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, src, needle).?);
        }
    }.of;
    // On `@import` and on its string: the target in each module, by module priority
    for ([_]u32{ at("\"cfg\"") + 1, at("@import(\"cfg") + 1 }) |offset| {
        try testing.expectEqualStrings("exe_cfg.zig: test_cfg.zig:", try w.gotoAll(main.file, offset, definition.definitionTargets));
        try testing.expectEqualStrings("exe_cfg.zig: test_cfg.zig:", try w.gotoAll(main.file, offset, definition.declarationTargets));
        // The single-target entry point takes the target in the highest-priority module
        try testing.expectEqualStrings("exe_cfg.zig:", try w.goto(main.file, offset));
    }
    // At a use of the alias and at its name: definition goes to the target in each module,
    // declaration stops at the declaration
    for ([_]u32{ at("cfg.mode"), at("cfg =") }) |offset| {
        try testing.expectEqualStrings("exe_cfg.zig: test_cfg.zig:", try w.gotoAll(main.file, offset, definition.definitionTargets));
        try testing.expectEqualStrings("exe_cfg.zig:", try w.goto(main.file, offset));
    }
    try testing.expectEqualStrings("main.zig:cfg", try w.gotoAll(main.file, at("cfg.mode"), definition.declarationTargets));
    try testing.expectEqualStrings("util.zig:", try w.gotoAll(main.file, at("util.helper"), definition.definitionTargets));
    // A member lists the member at the same path in the target of each module
    try testing.expectEqualStrings("exe_cfg.zig:mode test_cfg.zig:mode", try w.gotoAll(main.file, at("mode;"), definition.definitionTargets));
    // A name whose target is the same in every module, and a relative path, have only one target
    try testing.expectEqualStrings("util.zig:", try w.gotoAll(main.file, at("\"util\""), definition.definitionTargets));
    try testing.expectEqualStrings("local.zig:", try w.gotoAll(main.file, at("\"local.zig\""), definition.definitionTargets));
    try testing.expectEqualStrings("util.zig:helper", try w.gotoAll(main.file, at("helper()"), definition.definitionTargets));
    // No target
    try testing.expectEqualStrings("", try w.gotoAll(main.file, at("void"), definition.definitionTargets));
}

test "definition follows an alias of `@import` to the imported file" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/inner.zig", "pub const value = 1;\n");
    const other = try w.add("/p/other.zig", "pub const inner = @import(\"inner.zig\");\n");
    const src =
        \\const other = @import("other.zig");
        \\const inner = other.inner;
        \\test {
        \\    const local = @import("inner.zig");
        \\    var copy = local;
        \\    _ = .{ inner.value, local.value, &copy };
        \\}
    ;
    const main = try w.add("/p/main.zig", src);
    const at = struct {
        fn of(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, src, needle).?);
        }
    }.of;
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "other =", "other.zig:", "main.zig:other" },
        .{ "other.inner", "other.zig:", "main.zig:other" },
        // Through an alias whose last hop is an `@import` in another file
        .{ "inner =", "inner.zig:", "main.zig:inner" },
        .{ "inner.value", "inner.zig:", "main.zig:inner" },
        .{ "local.value", "inner.zig:", "main.zig:local" },
        // A variable is not an alias
        .{ "copy =", "main.zig:copy", "main.zig:copy" },
    }) |c| {
        try testing.expectEqualStrings(c[1], try w.gotoAll(main.file, at(c[0]), definition.definitionTargets));
        try testing.expectEqualStrings(c[1], try w.goto(main.file, at(c[0])));
        try testing.expectEqualStrings(c[2], try w.gotoAll(main.file, at(c[0]), definition.declarationTargets));
    }
    // The member reached through the alias is still the member
    try testing.expectEqualStrings("inner.zig:value", try w.goto(main.file, at("value, local")));
    try testing.expectEqualStrings("inner.zig:", try w.goto(other.file, 10));
}

test "definition of an alias through a module import that differs between the modules of a file" {
    // Prevents definition from listing only the target in the highest-priority module when an
    // alias, rather than a use, goes through the import
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:a deps:cfg=cfga module:b deps:cfg=cfgb
        \\const cfg = @import("cfg");
        \\const inner = cfg.inner;
        \\const value = cfg.value;
        \\test {
        \\    _ = .{ inner.x, value };
        \\}
        \\//- /p/cfg_a.zig module:cfga
        \\pub const inner = @import("inner_a.zig");
        \\pub const value: u32 = 1;
        \\//- /p/cfg_b.zig module:cfgb
        \\pub const inner = @import("inner_b.zig");
        \\pub const value: u32 = 2;
        \\//- /p/inner_a.zig
        \\pub const x = 1;
        \\//- /p/inner_b.zig
        \\pub const x = 2;
    );
    const main = f.file("/p/main.zig");
    const text = blk: {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        break :blk try w.arena.allocator().dupe(u8, (try ctx.get(database.syntax.SourceText, main)).text);
    };
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "inner =", "inner_a.zig: inner_b.zig:", "main.zig:inner" },
        .{ "inner.x", "inner_a.zig: inner_b.zig:", "main.zig:inner" },
        .{ "value =", "cfg_a.zig:value cfg_b.zig:value", "main.zig:value" },
        .{ "value }", "cfg_a.zig:value cfg_b.zig:value", "main.zig:value" },
    }) |c| {
        try testing.expectEqualStrings(c[1], try w.gotoAll(main, at(text, c[0]), definition.definitionTargets));
        try testing.expectEqualStrings(c[2], try w.gotoAll(main, at(text, c[0]), definition.declarationTargets));
    }
    try testing.expectEqualStrings("inner_a.zig:", try w.goto(main, at(text, "inner =")));
}

test "goto and references on a member path past a module import that differs between the modules of a file" {
    // Prevents goto and references from taking only the highest-priority module's target when the
    // member is in a file reached past the import
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:a deps:cfg=cfga module:b deps:cfg=cfgb
        \\const cfg = @import("cfg");
        \\const value = cfg.sub.value;
        \\const sub = cfg.sub;
        \\test {
        \\    const local = cfg.sub;
        \\    _ = .{ value, cfg.sub.value, sub.value, local.value, cfg.direct };
        \\}
        \\//- /p/cfg_a.zig module:cfga
        \\pub const sub = @import("sub_a.zig");
        \\pub const direct = sub.value;
        \\//- /p/cfg_b.zig module:cfgb
        \\pub const sub = @import("sub_b.zig");
        \\pub const direct = sub.value;
        \\//- /p/sub_a.zig
        \\pub const value = 1;
        \\//- /p/sub_b.zig
        \\pub const value = 2;
    );
    const main = f.file("/p/main.zig");
    const text = blk: {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        break :blk try w.arena.allocator().dupe(u8, (try ctx.get(database.syntax.SourceText, main)).text);
    };
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    const both = "sub_a.zig:value sub_b.zig:value";
    for ([_]struct { u32, []const u8, []const u8 }{
        // The member at the end of the path, directly and through aliases of the path or a prefix
        .{ at(text, "cfg.sub.value,") + 8, both, both },
        .{ at(text, "sub.value, local") + 4, both, both },
        .{ at(text, "local.value") + 6, both, both },
        .{ at(text, "sub.value;") + 4, both, both },
        // An alias of the path: definition follows it, declaration stays on it
        .{ at(text, "value ="), both, "main.zig:value" },
        .{ at(text, "value, cfg"), both, "main.zig:value" },
        .{ at(text, "sub ="), "sub_a.zig: sub_b.zig:", "main.zig:sub" },
        .{ at(text, "direct }"), both, "cfg_a.zig:direct cfg_b.zig:direct" },
    }) |c| {
        try testing.expectEqualStrings(c[1], try w.gotoAll(main, c[0], definition.definitionTargets));
        try testing.expectEqualStrings(c[2], try w.gotoAll(main, c[0], definition.declarationTargets));
    }

    // Each use of the path is a reference of the member in both files, ambiguous for rename
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    for ([_][]const u8{ "/p/sub_a.zig", "/p/sub_b.zig" }) |path| {
        const sub = f.file(path);
        const sub_text = (try ctx.get(database.syntax.SourceText, sub)).text;
        const def = try definition.defAt(&r, sub, at(sub_text, "value")) orelse return error.NoDefinition;
        var ambiguous: ?search.Reference = null;
        const refs = try search.findReferences(&r, def, .{ .scope = f.files, .ambiguous = &ambiguous });
        var in_main: usize = 0;
        for (refs) |ref| if (ref.file == main) {
            in_main += 1;
            try testing.expectEqualStrings("value", text[ref.start..ref.end]);
        };
        // `cfg.sub.value` twice, `sub.value`, `local.value`
        try testing.expectEqual(4, in_main);
        try testing.expectEqual(main, ambiguous.?.file);
    }
}

test "goto and references on members of a module import that differs between the modules of a file" {
    // Prevents goto from listing only the member in the highest-priority module's target
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:a deps:cfg=cfga module:b deps:cfg=cfgb
        \\const cfg = @import("cfg");
        \\pub fn main() void {
        \\    const v = cfg.value;
        \\    const m: cfg.Mode = .fast;
        \\    _ = .{ v, m };
        \\}
        \\//- /p/cfg_a.zig module:cfga
        \\pub const value: u32 = 1;
        \\pub const Mode = enum { fast, small };
        \\//- /p/cfg_b.zig module:cfgb
        \\pub const value: u32 = 2;
        \\pub const Mode = enum { small, fast };
    );
    const main = f.file("/p/main.zig");
    const text = blk: {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        break :blk try w.arena.allocator().dupe(u8, (try ctx.get(database.syntax.SourceText, main)).text);
    };
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    for ([_]struct { []const u8, []const u8 }{
        .{ "value;", "cfg_a.zig:value cfg_b.zig:value" },
        .{ "Mode =", "cfg_a.zig:Mode cfg_b.zig:Mode" },
        .{ "fast;", "cfg_a.zig:fast cfg_b.zig:fast" },
    }) |c| {
        try testing.expectEqualStrings(c[1], try w.gotoAll(main, at(text, c[0]), definition.definitionTargets));
        try testing.expectEqualStrings(c[1], try w.gotoAll(main, at(text, c[0]), definition.declarationTargets));
    }
    try testing.expectEqualStrings("cfg_a.zig:Mode cfg_b.zig:Mode", try w.gotoAll(main, at(text, "m }"), definition.typeDefinitionTargets));

    // A use refers to the member in each module: it is a reference of both, ambiguous for rename
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    for ([_][]const u8{ "/p/cfg_a.zig", "/p/cfg_b.zig" }) |path| {
        const cfg = f.file(path);
        const cfg_text = (try ctx.get(database.syntax.SourceText, cfg)).text;
        for ([_][]const u8{ "value", "fast" }) |name| {
            const def = try definition.defAt(&r, cfg, at(cfg_text, name)) orelse return error.NoDefinition;
            var ambiguous: ?search.Reference = null;
            const refs = try search.findReferences(&r, def, .{ .scope = f.files, .ambiguous = &ambiguous });
            var in_main: usize = 0;
            for (refs) |ref| if (ref.file == main) {
                in_main += 1;
                try testing.expectEqualStrings(name, text[ref.start..ref.end]);
            };
            try testing.expectEqual(1, in_main);
            try testing.expectEqual(main, ambiguous.?.file);
        }
    }
}

test "module alternatives cache is not reused across resolver contexts" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:a deps:cfg=cfga module:b deps:cfg=cfgb
        \\const cfg = @import("cfg");
        \\const value = cfg.value;
        \\//- /p/cfg_a.zig module:cfga
        \\pub const value: u32 = 1;
        \\//- /p/cfg_b.zig module:cfgb
        \\pub const value: u32 = 2;
    );
    const main = f.file("/p/main.zig");
    const cfg_a = f.file("/p/cfg_a.zig");
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator(), .context = 0 };
    const text = (try ctx.get(database.syntax.SourceText, cfg_a)).text;
    const def = try definition.defAt(&r, cfg_a, @intCast(std.mem.indexOf(u8, text, "value").?)) orelse return error.NoDefinition;
    var cache: resolve.ImportTargetCache = .empty;
    try testing.expectEqual(@as(usize, 1), (try r.moduleAlternatives(main, def, &cache)).len);
    try testing.expectEqual(@as(?u32, 0), cache.get(main).?.context);
    // A list computed for another compilation is not reused
    r.context = 1;
    try testing.expectEqual(@as(usize, 1), (try r.moduleAlternatives(main, def, &cache)).len);
    try testing.expectEqual(@as(?u32, 1), cache.get(main).?.context);
}

test "@This, enums, nested containers and generic functions" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\const Color = enum { red, green, pub fn dark() void {} };
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        items: []T,
        \\        fn len(self: Self) usize { return self.items.len; }
        \\        fn first(self: Self) void { _ = Self.len; _ = Color.green; <|> }
        \\    };
        \\}
    ;
    const f = try w.add("/p/main.zig", src);
    const text = try std.mem.replaceOwned(u8, w.arena.allocator(), src, "<|>", "");
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    // A container inside a body references a parameter of the enclosing function
    try testing.expectEqualStrings("main.zig:T", try w.goto(f.file, at(text, "T,")));
    try testing.expectEqualStrings("main.zig:len", try w.goto(f.file, at(text, "len; _")));
    try testing.expectEqualStrings("main.zig:green", try w.goto(f.file, at(text, "green; ")));
    // Visible names: parameters, container members, parameters of the enclosing function, and
    // file-level declarations
    try testing.expectEqualStrings("Color List Self T first len self", try w.complete(f.file, f.cursor));
}

test "files that are not loaded are read from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.zig", .data = "pub const thing = 1;\n" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const main_path = try std.fs.path.join(testing.allocator, &.{ dir, "main.zig" });
    defer testing.allocator.free(main_path);
    const file = try w.vfs.intern(main_path);
    const text = "const other = @import(\"other.zig\");\nconst x = other.thing;\n";
    {
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(FileText, file, try testing.allocator.dupe(u8, text), .low);
    }
    try testing.expectEqualStrings("other.zig:thing", try w.goto(file, @intCast(std.mem.indexOf(u8, text, "thing").?)));
}

test "a container-level variable does not resolve its own name in its initializer" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;

    // The compiler rejects `const x = x;`, `var x = x;` and the same reference from a block in the
    // initializer: the declaration depends on itself. goto must report no definition.
    const own = "const x = x;\n";
    const own_file = try w.add("/p/own.zig", own);
    try testing.expectEqualStrings("null", try w.goto(own_file.file, at(own, "x;")));

    const variable = "var x = x;\n";
    const variable_file = try w.add("/p/variable.zig", variable);
    try testing.expectEqualStrings("null", try w.goto(variable_file.file, at(variable, "x;")));

    const block = "const x = blk: { const y = x; break :blk 1; };\n";
    const block_file = try w.add("/p/block.zig", block);
    try testing.expectEqualStrings("null", try w.goto(block_file.file, at(block, "x;")));

    const nested_own = "const S = struct { const x = x; };\n";
    const nested_own_file = try w.add("/p/nested_own.zig", nested_own);
    try testing.expectEqualStrings("null", try w.goto(nested_own_file.file, at(nested_own, "x; }")));

    // Container-level forward references are legal.
    const forward = "const a = b;\nconst b = 1;\n";
    const forward_file = try w.add("/p/forward.zig", forward);
    try testing.expectEqualStrings("forward.zig:b", try w.goto(forward_file.file, at(forward, "b;")));

    // A function body may refer to the function itself.
    const recursive = "fn f() void { _ = f; }\n";
    const recursive_file = try w.add("/p/recursive.zig", recursive);
    try testing.expectEqualStrings("recursive.zig:f", try w.goto(recursive_file.file, at(recursive, "f; }")));

    // Nested bodies are separate items, so they still see the declaration they belong to.
    const nested_fn = "const x = struct { fn f() void { _ = x; } };\n";
    const nested_fn_file = try w.add("/p/nested_fn.zig", nested_fn);
    try testing.expectEqualStrings("nested_fn.zig:x", try w.goto(nested_fn_file.file, at(nested_fn, "x; }")));

    const nested_const = "const x = struct { const y = x; };\n";
    const nested_const_file = try w.add("/p/nested_const.zig", nested_const);
    try testing.expectEqualStrings("nested_const.zig:x", try w.goto(nested_const_file.file, at(nested_const, "x; }")));

    const field = "const x = struct { a: u32 = blk: { _ = x; break :blk 1; } };\n";
    const field_file = try w.add("/p/field.zig", field);
    try testing.expectEqualStrings("field.zig:x", try w.goto(field_file.file, at(field, "x; break")));

    const other = "const x = 1;\nconst y = x;\n";
    const other_file = try w.add("/p/other.zig", other);
    try testing.expectEqualStrings("other.zig:x", try w.goto(other_file.file, at(other, "x;")));
}

test "alias targets distinguish bare primitives from escaped declarations" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig",
        \\const @"u32" = struct {};
        \\const Bare = u32;
        \\const Quoted = @"u32";
        \\const Chained = Bare;
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const tree = try r.itemTree(added.file);
    const escaped = resolve.Resolver.lookupDecl(tree, 0, "u32").?;
    const bare = resolve.Resolver.lookupDecl(tree, 0, "Bare").?;
    const quoted = resolve.Resolver.lookupDecl(tree, 0, "Quoted").?;
    const chained = resolve.Resolver.lookupDecl(tree, 0, "Chained").?;
    try testing.expectEqualDeep(resolve.Def{ .item = .{ .file = added.file, .item = bare } }, try r.aliasTarget(.{ .item = .{ .file = added.file, .item = bare } }));
    try testing.expectEqualDeep(resolve.Def{ .item = .{ .file = added.file, .item = escaped } }, try r.aliasTarget(.{ .item = .{ .file = added.file, .item = quoted } }));
    try testing.expectEqualDeep(resolve.Def{ .item = .{ .file = added.file, .item = bare } }, try r.aliasTarget(.{ .item = .{ .file = added.file, .item = chained } }));
    try testing.expect(try r.namespaceOf(.{ .item = .{ .file = added.file, .item = bare } }) == null);
    try testing.expect(try r.namespaceOf(.{ .item = .{ .file = added.file, .item = chained } }) == null);
    try testing.expectEqualDeep(
        (try r.namespaceOf(.{ .item = .{ .file = added.file, .item = escaped } })).?,
        (try r.namespaceOf(.{ .item = .{ .file = added.file, .item = quoted } })).?,
    );
}

test "members of another file resolve only when pub" {
    // `other.hidden` is a compile error, not a reference to the declaration
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/other.zig
        \\const hidden: u32 = 1;
        \\pub const shown: u32 = 2;
        \\pub const E = enum { a, b };
        \\//- /p/main.zig
        \\const other = @import("other.zig");
        \\const alias = other;
        \\test {
        \\    _ = other.hidden;
        \\    _ = other.shown;
        \\    _ = other.E.a;
        \\    _ = alias.hidden;
        \\    _ = alias.shown;
        \\    other.<|>
        \\}
    );
    const main = f.file("/p/main.zig");
    const text = blk: {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        break :blk try w.arena.allocator().dupe(u8, (try ctx.get(database.syntax.SourceText, main)).text);
    };
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    try testing.expectEqualStrings("null", try w.goto(main, at(text, "hidden;")));
    try testing.expectEqualStrings("other.zig:shown", try w.goto(main, at(text, "shown;")));
    // Enum fields are not gated by `pub`
    try testing.expectEqualStrings("other.zig:a", try w.goto(main, at(text, "a;")));
    // The same through an alias
    try testing.expectEqualStrings("null", try w.goto(main, at(text, "alias.hidden") + 6));
    try testing.expectEqualStrings("other.zig:shown", try w.goto(main, at(text, "alias.shown") + 6));
    // Completion offers only pub declarations of another file
    try testing.expectEqualStrings("E shown", try w.complete(main, f.cursor.?.offset));
}

test "decl literals of another file resolve only when pub" {
    // `.secret` with a result type from another file is a compile error, not a reference
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/other.zig
        \\pub const S = struct {
        \\    v: i32 = 1,
        \\    const secret: S = .{ .v = 7 };
        \\    pub const shown: S = .{ .v = 8 };
        \\    fn hidden() S { return .{ .v = 9 }; }
        \\    const own: S = .secret;
        \\};
        \\//- /p/main.zig
        \\const other = @import("other.zig");
        \\test {
        \\    const x: other.S = .secret;
        \\    const y: other.S = .shown;
        \\    const z: other.S = .hidden();
        \\    _ = .{ x, y, z };
        \\}
    );
    const main = f.file("/p/main.zig");
    const other = f.file("/p/other.zig");
    const at = struct {
        fn of(w2: *World, file: FileId, needle: []const u8) !u32 {
            var ctx = w2.db.beginRead(w2.arena.allocator());
            defer ctx.end();
            const t = (try ctx.get(database.syntax.SourceText, file)).text;
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    try testing.expectEqualStrings("null", try w.goto(main, try at(&w, main, "secret;")));
    try testing.expectEqualStrings("other.zig:shown", try w.goto(main, try at(&w, main, "shown;")));
    try testing.expectEqualStrings("null", try w.goto(main, try at(&w, main, "hidden(")));
    // A private declaration is a decl literal in its own file
    try testing.expectEqualStrings("other.zig:secret", try w.goto(other, try at(&w, other, "secret;")));
}

test "members of the same file resolve through a self-import" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/self.zig
        \\const self = @import("self.zig");
        \\const hidden: u32 = 1;
        \\pub const shown: u32 = 2;
        \\test {
        \\    _ = self.hidden;
        \\    _ = self.shown;
        \\}
    );
    const self_file = f.file("/p/self.zig");
    const text = blk: {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        break :blk try w.arena.allocator().dupe(u8, (try ctx.get(database.syntax.SourceText, self_file)).text);
    };
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    try testing.expectEqualStrings("self.zig:hidden", try w.goto(self_file, at(text, "hidden;")));
    try testing.expectEqualStrings("self.zig:shown", try w.goto(self_file, at(text, "shown;")));
}
