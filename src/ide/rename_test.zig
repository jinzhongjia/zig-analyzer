const std = @import("std");
const testing = std.testing;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const definition = @import("definition.zig");
const search = @import("../ide_db/search.zig");
const rename = @import("rename.zig");
const World = @import("../names/resolve_test.zig").World;

const Check = enum { declaration, resolution };

/// Problem with renaming the definition at `<|>` to `new`: "line:column message" (lines and
/// columns start at 1); "ok" when there is no problem
fn problemOf(text: []const u8, new: []const u8, comptime check: Check) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const def = (try definition.defAt(&r, added.file, added.cursor)) orelse return error.NoDefinition;
    const problem = switch (check) {
        .declaration => try rename.declarationConflict(&r, def, new),
        .resolution => try rename.resolutionConflict(&r, def, new),
    } orelse return testing.allocator.dupe(u8, "ok");
    const clean = (try ctx.get(database.syntax.SourceText, added.file)).text;
    return format(clean, problem);
}

fn format(text: []const u8, p: rename.Problem) ![]const u8 {
    const line = std.mem.count(u8, text[0..p.offset], "\n") + 1;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..p.offset], '\n')) |i| i + 1 else 0;
    return std.fmt.allocPrint(testing.allocator, "{d}:{d} {s}", .{ line, p.offset - line_start + 1, p.message });
}

fn expectProblem(text: []const u8, new: []const u8, comptime check: Check, expected: []const u8) !void {
    const got = try problemOf(text, new, check);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "rename: conflicts at the declaration" {
    // A field and a declaration in the same container cannot share a name
    try expectProblem(
        \\const S = struct {
        \\    fooBar: u32,
        \\    fn <|>other() void {}
        \\};
    , "fooBar", .declaration, "2:5 `fooBar` is already declared in the same container");
    // A local name cannot shadow outer local names or declarations
    try expectProblem(
        \\fn f() void {
        \\    const a = 1;
        \\    {
        \\        const <|>b = 2;
        \\        _ = b;
        \\    }
        \\    _ = a;
        \\}
    , "a", .declaration, "2:11 `a` is already declared in this scope");
    try expectProblem(
        \\const top = 1;
        \\fn f() void {
        \\    const <|>x = 2;
        \\    _ = x;
        \\}
    , "top", .declaration, "1:7 the new name `top` would shadow this declaration");
    // A same-named local name deeper within the scope would shadow the renamed name
    try expectProblem(
        \\fn f(<|>p: u32) void {
        \\    const q = p;
        \\    _ = q;
        \\}
    , "q", .declaration, "2:11 this `q` would shadow the renamed name");
    // A declaration in a container inside a function body cannot shadow local names visible
    // in the function
    try expectProblem(
        \\fn f() type {
        \\    const v = 1;
        \\    return struct {
        \\        const <|>w = v;
        \\    };
        \\}
    , "v", .declaration, "2:11 the new name `v` would shadow this local");
    // Same-named local names in different branches cannot see each other
    try expectProblem(
        \\fn f(c: bool) void {
        \\    if (c) {
        \\        const <|>a = 1;
        \\        _ = a;
        \\    } else {
        \\        const b = 2;
        \\        _ = b;
        \\    }
        \\}
    , "b", .declaration, "ok");
}

test "rename: references that would become ambiguous" {
    // A declaration in a container may share its name with an outer one, but after the rename,
    // references in the container to the outer `x` would see both (`ambiguous reference`)
    try expectProblem(
        \\const x = 1;
        \\const S = struct {
        \\    const <|>y = 2;
        \\    fn f() u32 {
        \\        return x;
        \\    }
        \\};
    , "x", .resolution, "5:16 this `x` would be an ambiguous reference: it refers to another declaration, and the renamed declaration would be visible here too");
    // A reference to it would also see a closer declaration with the same name
    try expectProblem(
        \\const S = struct {
        \\    const <|>old = 1;
        \\    const T = struct {
        \\        const new = 2;
        \\        fn f() u32 {
        \\            return old;
        \\        }
        \\    };
        \\};
    , "new", .resolution, "6:20 this reference would be an ambiguous reference: another `new` is declared closer to it");
    // The outer declaration with the same name is not referenced in the container
    try expectProblem(
        \\const x = 1;
        \\const S = struct {
        \\    const <|>y = 2;
        \\    fn f() u32 {
        \\        return y;
        \\    }
        \\};
        \\pub fn main() void {
        \\    _ = x;
        \\}
    , "x", .resolution, "ok");
}

test "rename: names referenced by string literals" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\const S = struct { fooBar: u32, other: u32 };
        \\// "other"
        \\fn f(s: S) u32 {
        \\    const @"other" = 1;
        \\    _ = @"other";
        \\    return @field(s, "fooBar");
        \\}
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const p = (try rename.stringReference(&r, &.{file}, "fooBar")).?;
    const got = try format(text, p);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("6:22 `fooBar` appears in a string literal, which may refer to it by name (as `@field` and serialization do) and would not be updated", got);
    // Occurrences in comments and identifiers of the form `@"..."` do not count
    try testing.expectEqual(null, try rename.stringReference(&r, &.{file}, "other"));
}

test "rename: test names are not string references" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\pub fn area(x: u32) u32 {
        \\    return x * x;
        \\}
        \\const S = struct {
        \\    test "area" {}
        \\};
        \\test "area" {
        \\    _ = area(3);
        \\    _ = "side";
        \\}
        \\test "side" {}
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    // A rename of `area` once failed because of the test names, top-level and nested
    try testing.expectEqual(null, try rename.stringReference(&r, &.{file}, "area"));
    // Other string literals inside a test body still count
    const p = (try rename.stringReference(&r, &.{file}, "side")).?;
    const got = try format(text, p);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("9:9 `side` appears in a string literal, which may refer to it by name (as `@field` and serialization do) and would not be updated", got);
}

test "rename: declarations the standard library looks up in the root source file" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const root_text =
        \\const std = @import("std");
        \\const lib = @import("lib.zig");
        \\pub const std_options: std.Options = .{};
        \\pub const panic = std.debug.FullPanic(lib.onPanic);
        \\pub const debug = struct {
        \\    pub const SelfInfo = void;
        \\    pub const other = 1;
        \\};
        \\pub fn main() void {}
        \\pub fn helper() void {}
        \\
    ;
    const lib_text = "pub fn onPanic(msg: []const u8, ra: ?usize) noreturn {\n    _ = msg;\n    _ = ra;\n    unreachable;\n}\npub fn main() void {}\n";
    const fx = try w.fixture("//- /p/main.zig module:app\n" ++ root_text ++ "//- /p/lib.zig in:app\n" ++ lib_text);
    const root = fx.file("/p/main.zig");
    const lib = fx.file("/p/lib.zig");
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const root_src = (try ctx.get(database.syntax.SourceText, root)).text;
    for ([_]struct { []const u8, ?[]const u8 }{
        .{ "std_options", "3:11 the standard library looks up `root.std_options` by this name in the root source file" },
        .{ "panic", "4:11 the standard library looks up `root.panic` by this name in the root source file" },
        .{ "SelfInfo", "6:15 the standard library looks up `root.debug.SelfInfo` by this name in the root source file" },
        .{ "main", "9:8 the standard library looks up `root.main` by this name in the root source file" },
        .{ "other", null },
        .{ "helper", null },
    }) |c| {
        const def = (try definition.defAt(&r, root, @intCast(std.mem.indexOf(u8, root_src, c[0]).?))).?;
        const problem = try rename.stdRootLookup(&r, def);
        if (c[1]) |expected| {
            const got = try format(root_src, problem.?);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(expected, got);
        } else try testing.expectEqual(null, problem);
    }
    // `main` of a file that is not the root of its compilation is not looked up
    const lib_src = (try ctx.get(database.syntax.SourceText, lib)).text;
    const lib_main = (try definition.defAt(&r, lib, @intCast(std.mem.indexOf(u8, lib_src, "main").?))).?;
    try testing.expectEqual(null, try rename.stdRootLookup(&r, lib_main));
}

/// Extra AstGen error after renaming all references of the definition at `<|>` to `new`; with
/// `skip_uses`, only the declaration is renamed (simulating references missed by the rename)
fn verify(text: []const u8, new: []const u8, skip_uses: bool) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const def = (try definition.defAt(&r, added.file, added.cursor)) orelse return error.NoDefinition;
    var edits: std.ArrayList(rename.Edit) = .empty;
    for (try search.findReferences(&r, def, .{ .scope = &.{added.file} })) |ref| {
        if (skip_uses and !ref.is_decl) continue;
        try edits.append(a, .{ .start = ref.start, .end = ref.end, .text = new });
    }
    const problem = try rename.verifyAstGen(&r, added.file, edits.items) orelse return testing.allocator.dupe(u8, "ok");
    return format((try ctx.get(database.syntax.SourceText, added.file)).text, problem);
}

fn expectVerify(text: []const u8, new: []const u8, skip_uses: bool, expected: []const u8) !void {
    const got = try verify(text, new, skip_uses);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "rename: AstGen confirms the renamed text" {
    const text =
        \\fn f() u32 {
        \\    const unused = 0;
        \\    const a = 1;
        \\    const <|>b = 2;
        \\    return a + b;
        \\}
    ;
    // Existing errors (the unused local constant) do not count
    try expectVerify(text, "c", false, "ok");
    try expectVerify(text, "a", false, "4:11 redeclaration of local constant 'a'");
    // A reference missed by the rename no longer resolves to the declaration
    try expectVerify(text, "c", true, "5:16 use of undeclared identifier 'b'");
}
