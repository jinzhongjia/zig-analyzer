const std = @import("std");
const testing = std.testing;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const definition = @import("../ide/definition.zig");
const search = @import("search.zig");
const World = @import("../names/resolve_test.zig").World;
const FileId = @import("../base/Vfs.zig").FileId;

const main_src =
    \\const lib = @import("lib.zig");
    \\const Color = lib.Color;
    \\pub fn main() void {
    \\    var p: lib.Point = .{ .x = 1, .y = 2 };
    \\    p.x += lib.add(p.x, 1);
    \\    const c: Color = .red;
    \\    switch (c) {
    \\        .red => {},
    \\        else => {},
    \\    }
    \\    const local = 3;
    \\    _ = local + local;
    \\}
;
const lib_src =
    \\pub const Point = struct { x: i32, y: i32 };
    \\pub const Color = enum { red, green };
    \\pub fn add(a: i32, b: i32) i32 {
    \\    return a + b;
    \\}
    \\test {
    \\    _ = add(1, 2);
    \\    const q = Point{ .x = 0, .y = 0 };
    \\    _ = q.x;
    \\}
;
// Does not import lib.zig: the declaration with the same name in it is not a reference
const other_src =
    \\fn add() void {}
    \\test {
    \\    add();
    \\}
;

const Files = struct { main: FileId, lib: FileId, other: FileId };

fn setup(w: *World) !Files {
    try w.init();
    return .{
        .main = (try w.add("/p/main.zig", main_src)).file,
        .lib = (try w.add("/p/lib.zig", lib_src)).file,
        .other = (try w.add("/p/other.zig", other_src)).file,
    };
}

/// Position of the `nth` occurrence of `needle` in `src`
fn at(src: []const u8, needle: []const u8, nth: usize) u32 {
    var start: usize = 0;
    for (0..nth) |_| start = std.mem.indexOfPos(u8, src, start, needle).? + 1;
    return @intCast(std.mem.indexOfPos(u8, src, start, needle).?);
}

/// Reference list: `file:line` entries joined by spaces (the definition is marked with `*`)
fn refs(w: *World, fs: Files, file: FileId, offset: u32, only_file: ?FileId) ![]const u8 {
    return symbolRefs(w, file, offset, .{ .scope = &.{ fs.main, fs.lib, fs.other }, .only_file = only_file });
}

/// References of the symbol at `offset` (see `refs`)
fn symbolRefs(w: *World, file: FileId, offset: u32, opts: search.Options) ![]const u8 {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const symbol = try definition.symbolAt(&r, file, offset) orelse return "null";
    const list = try search.symbolReferences(&r, symbol, opts);
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |ref, i| {
        const text = (try ctx.get(database.syntax.SourceText, ref.file)).text;
        const line = std.mem.count(u8, text[0..ref.start], "\n") + 1;
        if (i > 0) try out.append(w.arena.allocator(), ' ');
        try out.print(w.arena.allocator(), "{s}:{d}:{s}{s}", .{ std.fs.path.stem(w.vfs.path(ref.file)), line, text[ref.start..ref.end], if (ref.is_decl) "*" else "" });
    }
    return out.items;
}

test "find references" {
    var w: World = undefined;
    const fs = try setup(&w);
    defer w.deinit();
    const cases = [_]struct { FileId, []const u8, []const u8, usize, []const u8 }{
        // Cross-file function; the function with the same name in other.zig does not count
        .{ fs.lib, lib_src, "add(a", 0, "main:5:add lib:3:add* lib:7:add" },
        .{ fs.main, main_src, "add(p", 0, "main:5:add lib:3:add* lib:7:add" },
        // Field: accesses and initializations found by type inference
        .{ fs.lib, lib_src, "x: i32", 0, "main:4:x main:5:x main:5:x lib:1:x* lib:8:x lib:9:x" },
        // Enum member: enum literals
        .{ fs.lib, lib_src, "red", 0, "main:6:red main:8:red lib:2:red*" },
        // Declaration referenced through an alias
        .{ fs.lib, lib_src, "Color", 0, "main:2:Color lib:2:Color*" },
        // Local variable
        .{ fs.main, main_src, "local", 1, "main:11:local* main:12:local main:12:local" },
        .{ fs.other, other_src, "add", 1, "other:1:add* other:3:add" },
    };
    for (cases) |c| {
        const got = try refs(&w, fs, c[0], at(c[1], c[2], c[3]), null);
        testing.expectEqualStrings(c[4], got) catch |err| {
            std.debug.print("references of `{s}`\n", .{c[2]});
            return err;
        };
    }
    // Search in a single file only (document highlight)
    try testing.expectEqualStrings("lib:3:add* lib:7:add", try refs(&w, fs, fs.lib, at(lib_src, "add", 0), fs.lib));
}

test "references to standard library declarations from project files" {
    // Project files import only std.zig: the edge std.zig → mem.zig comes from a file outside the
    // search scope; without it, only mem.zig would be searched
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ModuleGraph = database.ModuleGraph;
    const std_root = try w.add("/zig/std/std.zig", "pub const mem = @import(\"mem.zig\");\nconst x = mem.eql;\n");
    const mem_src = "pub fn eql() bool {\n    return true;\n}\nconst y = eql;\n";
    const mem = try w.add("/zig/std/mem.zig", mem_src);
    const app_src = "const std = @import(\"std\");\npub fn main() void {\n    _ = std.mem.eql();\n}\n";
    const app = try w.add("/p/main.zig", app_src);
    const unrelated = try w.add("/p/other.zig", "fn eql() void {}\ntest {\n    eql();\n}\n");
    try w.setGraph(std_root.file, &.{.{ .root = app.file, .imports = &.{} }}, &.{
        .{ .file = app.file, .module = 0, .compile = 0 },
        .{ .file = unrelated.file, .module = 0, .compile = 0 },
        .{ .file = std_root.file, .module = ModuleGraph.std_module, .compile = 0 },
        .{ .file = mem.file, .module = ModuleGraph.std_module, .compile = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const def = try definition.defAt(&r, app.file, @intCast(std.mem.indexOf(u8, app_src, "eql").?)) orelse return error.NoDefinition;
    const list = try search.findReferences(&r, def, .{ .scope = &.{ app.file, unrelated.file } });
    var out: std.ArrayList(u8) = .empty;
    for (list) |ref| {
        const text = (try ctx.get(database.syntax.SourceText, ref.file)).text;
        try out.print(w.arena.allocator(), "{s}:{d}{s} ", .{ std.fs.path.stem(w.vfs.path(ref.file)), std.mem.count(u8, text[0..ref.start], "\n") + 1, if (ref.is_decl) "*" else "" });
    }
    // Other files outside the scope (std.zig) are not searched
    try testing.expectEqualStrings("mem:1* mem:4 main:3 ", out.items);
}

test "references reach files that import the definition through files outside the scope" {
    // The chains main → std.zig → mem.zig and app2 → config.zig → load.zig pass through files
    // outside the scope; they used to be dropped once the defining file was in the scope
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ModuleGraph = database.ModuleGraph;
    const std_root = try w.add("/zig/std/std.zig", "pub const mem = @import(\"mem.zig\");\n");
    const mem_src = "pub fn eql() bool {\n    return true;\n}\n";
    const mem = try w.add("/zig/std/mem.zig", mem_src);
    const app_src = "const std = @import(\"std\");\npub fn main() void {\n    _ = std.mem.eql();\n}\n";
    const app = try w.add("/p/main.zig", app_src);
    // A closed project file between the user and the definition: app2 → config.zig → load.zig
    const app2_src = "const config = @import(\"config.zig\");\ntest {\n    _ = config.load.load();\n}\n";
    const app2 = try w.add("/p/app2.zig", app2_src);
    _ = try w.add("/p/config.zig", "pub const load = @import(\"load.zig\");\n");
    const load_src = "pub fn load() u32 {\n    return 42;\n}\n";
    const load = try w.add("/p/load.zig", load_src);
    try w.setGraph(std_root.file, &.{.{ .root = app.file, .imports = &.{} }}, &.{
        .{ .file = app.file, .module = 0, .compile = 0 },
        .{ .file = std_root.file, .module = ModuleGraph.std_module, .compile = 0 },
        .{ .file = mem.file, .module = ModuleGraph.std_module, .compile = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const Case = struct { def_file: FileId, def_text: []const u8, name: []const u8, scope: []const FileId, only_file: ?FileId, expected: []const u8 };
    const cases = [_]Case{
        .{ .def_file = mem.file, .def_text = mem_src, .name = "eql", .scope = &.{ app.file, mem.file }, .only_file = null, .expected = "mem:1* main:3 " },
        .{ .def_file = mem.file, .def_text = mem_src, .name = "eql", .scope = &.{ app.file, mem.file }, .only_file = app.file, .expected = "main:3 " },
        .{ .def_file = load.file, .def_text = load_src, .name = "load", .scope = &.{ app2.file, load.file }, .only_file = null, .expected = "app2:3 load:1* " },
        .{ .def_file = load.file, .def_text = load_src, .name = "load", .scope = &.{ app2.file, load.file }, .only_file = app2.file, .expected = "app2:3 " },
    };
    for (cases) |c| {
        const def = try definition.defAt(&r, c.def_file, @intCast(std.mem.indexOf(u8, c.def_text, c.name).?)) orelse return error.NoDefinition;
        const list = try search.findReferences(&r, def, .{ .scope = c.scope, .only_file = c.only_file });
        var out: std.ArrayList(u8) = .empty;
        for (list) |ref| {
            const text = (try ctx.get(database.syntax.SourceText, ref.file)).text;
            try out.print(w.arena.allocator(), "{s}:{d}{s} ", .{ std.fs.path.stem(w.vfs.path(ref.file)), std.mem.count(u8, text[0..ref.start], "\n") + 1, if (ref.is_decl) "*" else "" });
        }
        try testing.expectEqualStrings(c.expected, out.items);
    }
}

test "enum member names are not references to declarations of the same name" {
    const src =
        \\pub fn read() void {}
        \\pub const SYS = enum(u32) { read = 0, write = 1 };
        \\pub const Tag = enum { read, other };
        \\test {
        \\    read();
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:read* x:5:read", try refs(&w, fs, f, at(src, "read", 0), null));
    // Searching at the member name finds the member itself, not the function with the same name
    try testing.expectEqualStrings("x:2:read*", try refs(&w, fs, f, at(src, "read", 1), null));
}

test "member references inside generic functions use the call-site instance" {
    const src =
        \\const S = struct { x: u32 };
        \\fn read(p: anytype) u32 {
        \\    return p.x;
        \\}
        \\pub fn main() void {
        \\    const s: S = .{ .x = 1 };
        \\    _ = read(s);
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:x* x:3:x x:6:x", try refs(&w, fs, f, at(src, "x", 0), null));
    // Only one instance: no ambiguity
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var ambiguous: ?search.Reference = null;
    _ = try search.findReferences(&r, (try definition.defAt(&r, f, at(src, "x", 0))).?, .{ .scope = &.{f}, .ambiguous = &ambiguous });
    try testing.expectEqual(null, ambiguous);
}

test "references to quoted names with escaped quotes" {
    const src =
        \\const S = struct { @"a\"b": u32 };
        \\pub fn f(s: S) u32 {
        \\    return s.@"a\"b";
        \\}
        \\const @"\x66oo": u8 = 7;
        \\const bar = foo + @"foo";
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:@\"a\\\"b\"* x:3:@\"a\\\"b\"", try refs(&w, fs, f, at(src, "@\"a", 0), null));
    // A quoted name and its plain spelling are the same name
    try testing.expectEqualStrings("x:5:@\"\\x66oo\"* x:6:foo x:6:@\"foo\"", try refs(&w, fs, f, at(src, "@\"\\x66", 0), null));
}

test "bare primitive names are not references to quoted declarations of the same name" {
    // `f32` in `addf3` is the float type even with `@"f32"` declared: it used to be a reference,
    // and renaming `@"f32"` rewrote the parameter types
    const src =
        \\pub const @"f32" = enum { soft, hard };
        \\pub fn addf3(a: f32, b: f32) f32 {
        \\    const mode = @"f32".hard;
        \\    _ = mode;
        \\    return a + b;
        \\}
        \\fn local() u32 {
        \\    const @"undefined": u32 = 7;
        \\    var y: u32 = undefined;
        \\    y = @"undefined";
        \\    return y;
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:@\"f32\"* x:3:@\"f32\"", try refs(&w, fs, f, at(src, "@\"f32\"", 0), null));
    try testing.expectEqualStrings("x:8:@\"undefined\"* x:10:@\"undefined\"", try refs(&w, fs, f, at(src, "@\"undefined\"", 0), null));
}

test "member references inside generic functions cover every call-site instance" {
    const src =
        \\const S = struct { x: u32 };
        \\const T = struct { x: u32 };
        \\fn both(p: anytype) u32 {
        \\    return p.x;
        \\}
        \\fn onlyS(p: anytype) u32 {
        \\    return p.x;
        \\}
        \\pub fn main() void {
        \\    _ = both(T{ .x = 2 });
        \\    _ = both(S{ .x = 1 });
        \\    _ = onlyS(S{ .x = 3 });
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    // The instance at the first call site is T: references in the S instance are still found
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:x* x:4:x x:7:x x:11:x x:12:x", try refs(&w, fs, f, at(src, "x", 0), null));

    // `p.x` in `both` refers to T.x under the T instance: ambiguous
    // (renaming would break the T instance)
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var ambiguous: ?search.Reference = null;
    const def = (try definition.defAt(&r, f, at(src, "x", 0))).?;
    _ = try search.findReferences(&r, def, .{ .scope = &.{f}, .ambiguous = &ambiguous });
    try testing.expectEqual(at(src, "p.x", 0), ambiguous.?.start);
    // T.x is ambiguous in `both` as well
    ambiguous = null;
    const t_def = (try definition.defAt(&r, f, at(src, "x", 1))).?;
    _ = try search.findReferences(&r, t_def, .{ .scope = &.{f}, .ambiguous = &ambiguous });
    try testing.expectEqual(at(src, "p.x", 0), ambiguous.?.start);
}

test "references in generic bodies use a call site instance" {
    const src =
        \\const Real = struct {
        \\    pub fn getenv(_: *Real) ?[]const u8 {
        \\        return null;
        \\    }
        \\};
        \\fn lookup(comptime System: type, system: *System) ?[]const u8 {
        \\    return system.getenv();
        \\}
        \\pub fn main() void {
        \\    var s: Real = .{};
        \\    _ = lookup(Real, &s);
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    // `system` is unknown in abstract inference: like goto, take the instance at the call site
    // (`lookup(Real, ..)`)
    try testing.expectEqualStrings("x:2:getenv* x:7:getenv", try refs(&w, fs, f, at(src, "getenv", 0), null));
}

test "references in generic bodies use the instance a comptime type argument dispatches to" {
    // The file containing the dispatch site (`Q.compute(ctx)`) does not import the file containing
    // the callee: only goto used to find this instance; references and rename missed it
    const queries_src =
        \\pub const Cache = struct {
        \\    pub fn take(c: *Cache) u32 {
        \\        _ = c;
        \\        return 1;
        \\    }
        \\};
        \\pub const Item = struct {
        \\    pub fn compute(ctx: anytype) u32 {
        \\        return ctx.cache.take();
        \\    }
        \\};
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const engine_file = (try w.add("/p/engine.zig",
        \\pub fn Engine(comptime Ctx: type) type {
        \\    return struct {
        \\        pub fn get(ctx: *Ctx, comptime Q: type) u32 {
        \\            return Q.compute(ctx);
        \\        }
        \\    };
        \\}
    )).file;
    const queries_file = (try w.add("/p/queries.zig", queries_src)).file;
    const main_file = (try w.add("/p/main.zig",
        \\const Engine = @import("engine.zig").Engine;
        \\const queries = @import("queries.zig");
        \\const Ctx = struct { cache: queries.Cache };
        \\fn run(ctx: *Ctx) u32 {
        \\    return Engine(Ctx).get(ctx, queries.Item);
        \\}
    )).file;
    try w.setGraph(null, &.{.{ .root = main_file, .imports = &.{} }}, &.{
        .{ .file = engine_file, .module = 0, .compile = 0 },
        .{ .file = queries_file, .module = 0, .compile = 0 },
        .{ .file = main_file, .module = 0, .compile = 0 },
    });
    const fs: Files = .{ .main = main_file, .lib = queries_file, .other = engine_file };
    try testing.expectEqualStrings("queries:2:take* queries:9:take", try refs(&w, fs, queries_file, at(queries_src, "take", 0), null));
}

test "references to enum members include literals that a generic callee converts to the enum" {
    // `.green` received by an anytype parameter is converted by `@TypeOf(expected, actual)` in the
    // callee: it used not to count as a reference, and rename missed it
    const src =
        \\const Color = enum { red, green };
        \\fn expectEqual(expected: anytype, actual: anytype) !void {
        \\    const T = @TypeOf(expected, actual);
        \\    return expectEqualInner(T, expected, actual);
        \\}
        \\fn expectEqualInner(comptime T: type, expected: T, actual: T) !void {
        \\    if (expected != actual) return error.TestExpectedEqual;
        \\}
        \\test {
        \\    const c: Color = .green;
        \\    try expectEqual(.green, c);
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:green* x:10:green x:11:green", try refs(&w, fs, f, at(src, "green", 0), null));
}

test "references to tagged union fields through the type and error union results" {
    const src =
        \\const Value = union(enum) { null_val: void, int: i64 };
        \\fn parse(n: u8) error{Bad}!Value {
        \\    if (n == 0) return .null_val;
        \\    return .{ .int = n };
        \\}
        \\test {
        \\    _ = Value.null_val;
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:null_val* x:3:null_val x:7:null_val", try refs(&w, fs, f, at(src, "null_val", 0), null));
}

test "member accesses whose target cannot be determined are reported as uncertain" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\const S = struct { fooBar: u32, len: u32 };
        \\fn read(p: anytype) u32 {
        \\    return p.fooBar;
        \\}
        \\fn size(s: []const u8) usize {
        \\    return s.len;
        \\}
    ;
    const file = (try w.add("/p/main.zig", src)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    // The type of `p` is unknown and there is no call site: `p.fooBar` may be a reference
    {
        var uncertain: ?search.Reference = null;
        const def = (try definition.defAt(&r, file, at(src, "fooBar", 0))).?;
        _ = try search.findReferences(&r, def, .{ .scope = &.{file}, .uncertain = &uncertain });
        try testing.expectEqualStrings("p.fooBar", src[uncertain.?.start..uncertain.?.end]);
    }
    // `len` of a slice is not a member of S: the type is concrete, so the access is not uncertain
    {
        var uncertain: ?search.Reference = null;
        const def = (try definition.defAt(&r, file, at(src, "len", 0))).?;
        _ = try search.findReferences(&r, def, .{ .scope = &.{file}, .uncertain = &uncertain });
        try testing.expectEqual(null, uncertain);
    }
}

test "initializer field names are not uncertain references to other declarations" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\const S = struct {
        \\    range: u32,
        \\    pub fn span(s: S) u32 {
        \\        return s.range;
        \\    }
        \\};
        \\fn make(comptime T: type) T {
        \\    return .{ .span = 1, .range = 2 };
        \\}
    ;
    const file = (try w.add("/p/main.zig", src)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    // A field name in an initializer can only be a field: when `T` is unknown, `.span = 1` is not
    // a reference to the function `span` either
    {
        var uncertain: ?search.Reference = null;
        const def = (try definition.defAt(&r, file, at(src, "span", 0))).?;
        const found = try search.findReferences(&r, def, .{ .scope = &.{file}, .uncertain = &uncertain });
        try testing.expectEqual(null, uncertain);
        try testing.expectEqual(1, found.len);
    }
    // An initializer field with the same name as the field `range` still cannot be confirmed when
    // `T` is unknown
    {
        var uncertain: ?search.Reference = null;
        const def = (try definition.defAt(&r, file, at(src, "range", 0))).?;
        _ = try search.findReferences(&r, def, .{ .scope = &.{file}, .uncertain = &uncertain });
        try testing.expectEqualStrings("range", src[uncertain.?.start..uncertain.?.end]);
    }
}

test "literals whose result type is unknown are reported as uncertain" {
    // The literal keeps its own type when its result type is unknown: it used to be skipped as a
    // concrete type without the member, and fixes edited the other uses only
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\const Mode = enum { fastPath, slowPath };
        \\const Child = struct {
        \\    v: u32,
        \\    pub fn make(v: u32) Child {
        \\        return .{ .v = v };
        \\    }
        \\};
        \\fn touch(x: *Missing) bool {
        \\    x.child = .make(5);
        \\    x.lim = .{ .v = 3 };
        \\    switch (x.kind) {
        \\        .slowPath => {},
        \\        else => {},
        \\    }
        \\    return x.mode == .fastPath;
        \\}
    ;
    const file = (try w.add("/p/main.zig", src)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    for ([_]struct { []const u8, []const u8 }{
        .{ "make", ".make" },
        .{ "v:", "v" },
        .{ "fastPath", ".fastPath" },
        .{ "slowPath", ".slowPath" },
    }) |c| {
        var uncertain: ?search.Reference = null;
        const def = (try definition.defAt(&r, file, at(src, c[0], 0))).?;
        _ = try search.findReferences(&r, def, .{ .scope = &.{file}, .uncertain = &uncertain });
        const u = uncertain orelse {
            std.debug.print("no uncertain reference for `{s}`\n", .{c[0]});
            return error.NotUncertain;
        };
        try testing.expectEqualStrings(c[1], src[u.start..u.end]);
    }
}

test "files with syntax errors that mention the name are reported" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const lib =
        \\pub const S = struct { x: u32 };
    ;
    const main =
        \\const lib = @import("lib.zig");
        \\fn f(s: lib.S) u32 {
        \\    return s.x +;
        \\}
    ;
    const other =
        \\const lib = @import("lib.zig");
        \\fn g() void {
        \\    const y = ;
        \\}
    ;
    const lib_file = (try w.add("/p/lib.zig", lib)).file;
    const main_file = (try w.add("/p/main.zig", main)).file;
    const other_file = (try w.add("/p/other.zig", other)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var syntax_error: ?FileId = null;
    const def = (try definition.defAt(&r, lib_file, at(lib, "x", 0))).?;
    _ = try search.findReferences(&r, def, .{ .scope = &.{ lib_file, other_file, main_file }, .syntax_error = &syntax_error });
    // other.zig also has a syntax error, but does not contain the name
    try testing.expectEqual(main_file, syntax_error.?);
}

test "files that are never compiled together with the definition are not searched" {
    // `script.zig` is a separate root that does not import lib.zig: a syntax error in it that
    // mentions the name used to make renames of `x` refuse
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const lib = "pub const S = struct { x: u32 };\n";
    const main = "const lib = @import(\"lib.zig\");\nfn f(s: lib.S) u32 {\n    return s.x;\n}\n";
    const script = "fn g(p: anytype) u32 {\n    return p.x +;\n}\n";
    const lib_file = (try w.add("/p/lib.zig", lib)).file;
    const main_file = (try w.add("/p/main.zig", main)).file;
    const script_file = (try w.add("/p/script.zig", script)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var syntax_error: ?FileId = null;
    const def = (try definition.defAt(&r, lib_file, at(lib, "x", 0))).?;
    const list = try search.findReferences(&r, def, .{ .scope = &.{ lib_file, script_file, main_file }, .syntax_error = &syntax_error });
    try testing.expectEqual(null, syntax_error);
    try testing.expectEqual(2, list.len);
}

test "references in generic code of files that do not import the definition" {
    // Guards against searching only the files that import the file containing the definition:
    // `c.zig` does not import `a.zig` and calls `foo` through an anytype value
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a_src = "pub const S = struct {\n    pub fn foo(self: S) void {\n        _ = self;\n    }\n};\n";
    const c_src = "pub fn call(x: anytype) void {\n    x.foo();\n}\n";
    const main_text = "const a = @import(\"a.zig\");\nconst c = @import(\"c.zig\");\npub fn main() void {\n    c.call(a.S{});\n}\n";
    const fa = (try w.add("/p/a.zig", a_src)).file;
    const fc = (try w.add("/p/c.zig", c_src)).file;
    const fm = (try w.add("/p/main.zig", main_text)).file;
    try w.setGraph(null, &.{.{ .root = fm, .imports = &.{} }}, &.{
        .{ .file = fm, .module = 0, .compile = 0 },
        .{ .file = fa, .module = 0, .compile = 0 },
        .{ .file = fc, .module = 0, .compile = 0 },
    });
    var ctx = w.db.beginRead(testing.allocator);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const def = (try definition.defAt(&r, fa, at(a_src, "foo", 0))).?;
    const list = try search.findReferences(&r, def, .{ .scope = &.{ fa, fc, fm } });
    try testing.expectEqual(2, list.len);
    try testing.expectEqual(fc, list[1].file);
    try testing.expectEqual(at(c_src, "foo", 0), list[1].start);
}

test "members of a namespace chosen per configuration refer to every choice" {
    // Under the current configuration `Impl` is posix.zig, but on Windows `Impl.open` is win.zig's
    // `open`: it used to be no reference to it, and renaming either broke the other target
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const impl_src =
        \\const native = .linux;
        \\const win = @import("win.zig");
        \\const posix = @import("posix.zig");
        \\const Impl = switch (native) { .windows => win, else => posix };
        \\pub fn main() void {
        \\    Impl.open();
        \\}
    ;
    const fm = (try w.add("/p/main.zig", impl_src)).file;
    const fw = (try w.add("/p/win.zig", "pub fn open() void {}\n")).file;
    const fp = (try w.add("/p/posix.zig", "pub fn open() void {}\n")).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const use = at(impl_src, "open", 0);
    for ([_]FileId{ fw, fp }) |def_file| {
        const def = (try definition.defAt(&r, def_file, 7)).?;
        var ambiguous: ?search.Reference = null;
        const list = try search.findReferences(&r, def, .{ .scope = &.{ fm, fw, fp }, .ambiguous = &ambiguous });
        try testing.expectEqual(2, list.len);
        try testing.expect(for (list) |ref| {
            if (ref.file == fm and ref.start == use) break true;
        } else false);
        try testing.expectEqual(use - "Impl.".len, ambiguous.?.start);
    }
}

test "member accesses in a heterogeneous inline for refer to the member of each iteration" {
    // `shape.area()` is Circle.area in the first iteration and Square.area in the second: goto and
    // hover resolved it per iteration, but references dropped it and rename broke the build
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const shapes_src =
        \\pub const Circle = struct {
        \\    pub fn area(_: Circle) u32 {
        \\        return 1;
        \\    }
        \\};
        \\pub const Square = struct {
        \\    pub fn area(_: Square) u32 {
        \\        return 2;
        \\    }
        \\};
    ;
    const total_src =
        \\const shapes = @import("shapes.zig");
        \\fn total(c: shapes.Circle, s: shapes.Square) u32 {
        \\    var sum: u32 = 0;
        \\    inline for (.{ c, s }) |shape| sum += shape.area();
        \\    return sum;
        \\}
    ;
    const fs = (try w.add("/p/shapes.zig", shapes_src)).file;
    const fm = (try w.add("/p/main.zig", total_src)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const use = at(total_src, "area", 0);
    for ([_]usize{ 0, 1 }) |nth| {
        const def = (try definition.defAt(&r, fs, at(shapes_src, "area", nth))).?;
        var ambiguous: ?search.Reference = null;
        const list = try search.findReferences(&r, def, .{ .scope = &.{ fs, fm }, .ambiguous = &ambiguous });
        try testing.expectEqual(2, list.len);
        try testing.expectEqual(fm, list[1].file);
        try testing.expectEqual(use, list[1].start);
        try testing.expectEqual(use - "shape.".len, ambiguous.?.start);
    }
}

const jumps_src =
    \\const lib = @import("lib.zig");
    \\const E = error{ Oops, Other };
    \\const F = error{Oops};
    \\const Mode = enum { Oops, Calm };
    \\fn f(x: u32) E!u32 {
    \\    if (x == 0) return error.Oops;
    \\    if (x == 9) return E.Oops;
    \\    const v: u32 = blk: {
    \\        if (x == 1) break :blk 1;
    \\        break :blk 2;
    \\    };
    \\    const w: u32 = blk: {
    \\        break :blk 3;
    \\    };
    \\    var n: u32 = 0;
    \\    outer: while (n < 3) : (n += 1) {
    \\        inner: for (0..2) |_| {
    \\            if (n == 1) continue :outer;
    \\            if (n == 2) break :inner;
    \\        }
    \\        if (n == 2) break :outer;
    \\    }
    \\    sw: switch (x) {
    \\        0 => continue :sw 1,
    \\        else => {},
    \\    }
    \\    const m: Mode = .Oops;
    \\    _ = m;
    \\    return v + w + n;
    \\}
    \\fn g(x: anytype) void {
    \\    _ = x.Oops;
    \\}
    \\test {
    \\    const r = f(2) catch |err| switch (err) {
    \\        error.Oops => 0,
    \\        error.Other => 1,
    \\    };
    \\    _ = r;
    \\    _ = (E || F).Oops;
    \\    _ = Mode.Oops;
    \\    lib.h() catch {};
    \\}
;

test "labels and error names" {
    // Both had no references, highlight or rename although goto resolved them
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const lib_text =
        \\pub fn h() !void {
        \\    return error.Oops;
        \\}
    ;
    // Not compiled together with main.zig: its `error.Oops` is not the same error
    const other_text =
        \\fn k() !void {
        \\    return error.Oops;
        \\}
    ;
    const fm = (try w.add("/p/main.zig", jumps_src)).file;
    const fl = (try w.add("/p/lib.zig", lib_text)).file;
    const fo = (try w.add("/p/other.zig", other_text)).file;
    const scope: []const FileId = &.{ fm, fl, fo };
    const cases = [_]struct { []const u8, usize, []const u8 }{
        // Each `break` / `continue` targets the innermost enclosing expression with the label
        .{ "blk", 0, "main:8:blk* main:9:blk main:10:blk" },
        .{ "blk", 4, "main:12:blk* main:13:blk" },
        .{ "outer", 1, "main:16:outer* main:18:outer main:21:outer" },
        .{ "inner", 1, "main:17:inner* main:19:inner" },
        .{ "sw", 2, "main:23:sw* main:24:sw" },
        // Error names are global: every error set and `E.X` on an error set type, but not the enum
        // member with the same name
        .{ "Oops", 3, "main:2:Oops* main:3:Oops* main:6:Oops main:7:Oops main:36:Oops main:40:Oops lib:2:Oops" },
        .{ "Oops", 0, "main:2:Oops* main:3:Oops* main:6:Oops main:7:Oops main:36:Oops main:40:Oops lib:2:Oops" },
        .{ "Oops", 4, "main:2:Oops* main:3:Oops* main:6:Oops main:7:Oops main:36:Oops main:40:Oops lib:2:Oops" },
        .{ "Oops", 2, "main:4:Oops* main:27:Oops main:41:Oops" },
    };
    for (cases) |c| {
        const got = try symbolRefs(&w, fm, at(jumps_src, c[0], c[1]), .{ .scope = scope });
        testing.expectEqualStrings(c[2], got) catch |err| {
            std.debug.print("references of `{s}` #{d}\n", .{ c[0], c[1] });
            return err;
        };
    }
    // Document highlight: in one file
    try testing.expectEqualStrings("lib:2:Oops", try symbolRefs(&w, fl, at(lib_text, "Oops", 0), .{ .scope = &.{}, .only_file = fl }));
    try testing.expectEqualStrings("other:2:Oops", try symbolRefs(&w, fo, at(other_text, "Oops", 0), .{ .scope = scope }));
    // `x.Oops` on a value of unknown type may be the error
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var uncertain: ?search.Reference = null;
    _ = try search.symbolReferences(&r, (try definition.symbolAt(&r, fm, at(jumps_src, "Oops", 3))).?, .{ .scope = scope, .uncertain = &uncertain });
    try testing.expectEqual(at(jumps_src, "x.Oops", 0), uncertain.?.start);
}

test "targets of assignments are written" {
    // Every occurrence other than the declaration was reported as a read
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\const S = struct { f: u32 = 0 };
        \\test {
        \\    var n: u32 = 0;
        \\    n = 5;
        \\    n += 1;
        \\    var s: S = .{};
        \\    s.f = n;
        \\    s.f += 1;
        \\    _ = s.f;
        \\    var m: u32 = 0;
        \\    n, m = .{ m, n };
        \\}
    ;
    const file = (try w.add("/p/main.zig", src)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    for ([_]struct { []const u8, []const u8 }{
        .{ "n:", "3:decl 4:write 5:write 7:read 11:write 11:read" },
        .{ "f:", "1:decl 7:write 8:write 9:read" },
    }) |c| {
        const symbol = (try definition.symbolAt(&r, file, at(src, c[0], 0))).?;
        var out: std.ArrayList(u8) = .empty;
        for (try search.symbolReferences(&r, symbol, .{ .scope = &.{}, .only_file = file }), 0..) |ref, i| {
            if (i > 0) try out.append(w.arena.allocator(), ' ');
            const line = std.mem.count(u8, src[0..ref.start], "\n") + 1;
            try out.print(w.arena.allocator(), "{d}:{s}", .{ line, if (ref.is_decl) "decl" else if (ref.is_write) "write" else "read" });
        }
        try testing.expectEqualStrings(c[1], out.items);
    }
}

test "an unclosed block does not take the next declaration's locals as references" {
    // The `if` block of `main` is not closed: `fn helper` still starts a declaration of its own,
    // so renaming `main`'s `x` would otherwise edit `helper`'s parameter
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\pub fn main() void {
        \\    const x: u32 = 3;
        \\    if (x > 1) {
        \\        _ = 2;
        \\}
        \\
        \\fn helper(x: u32) void {
        \\    _ = x;
        \\}
        \\
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    try testing.expectEqualStrings("main:2:x* main:3:x", try symbolRefs(&w, file, at(text, "x", 0), .{ .scope = &.{file} }));
    try testing.expectEqualStrings("main:7:x* main:8:x", try symbolRefs(&w, file, at(text, "x", 2), .{ .scope = &.{file} }));
}

test "references to enum members include literals typed by the peer type of breaks and loop else values" {
    // Without a result type, `.b` in `break :blk .b` and in a loop `else` takes the peer type of
    // the other results: these literals used not to count as references, and rename missed them
    const src =
        \\const E = enum { a, b, c };
        \\const U = union(enum) { a: u8, b: void };
        \\fn pick(rt: bool, xs: []const u8) E {
        \\    const v1 = blk: {
        \\        if (rt) break :blk E.a;
        \\        break :blk .b;
        \\    };
        \\    const v2 = blk: {
        \\        if (rt) break :blk .b;
        \\        break :blk E.a;
        \\    };
        \\    var i: usize = 0;
        \\    const v3 = while (i < xs.len) : (i += 1) {
        \\        if (rt) break E.a;
        \\    } else .b;
        \\    const v4 = for (xs) |x| {
        \\        if (x == 0) break .b;
        \\    } else E.c;
        \\    const v5 = sw: switch (xs.len) {
        \\        0 => break :sw .b,
        \\        else => break :sw E.a,
        \\    };
        \\    const v6 = if (rt) E.c else .b;
        \\    const u = blk: {
        \\        if (rt) break :blk U{ .a = 1 };
        \\        break :blk .b;
        \\    };
        \\    _ = .{ v1, v2, v3, v4, v5, v6, u };
        \\    return v1;
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:b* x:6:b x:9:b x:15:b x:17:b x:20:b x:23:b", try refs(&w, fs, f, at(src, "b", 0), null));
    try testing.expectEqualStrings("x:2:b* x:26:b", try refs(&w, fs, f, at(src, "b: void", 0), null));
}
