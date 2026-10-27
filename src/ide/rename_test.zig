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

test "rename: references that would change their target" {
    // A declaration in a container may share its name with an outer one: after the rename,
    // references in the container that used to refer to the outer `x` would refer to it
    try expectProblem(
        \\const x = 1;
        \\const S = struct {
        \\    const <|>y = 2;
        \\    fn f() u32 {
        \\        return x;
        \\    }
        \\};
    , "x", .resolution, "5:16 this `x` refers to another declaration, which the renamed declaration would shadow");
    // A reference to it sees a closer declaration with the same name: after the rename, the
    // reference is captured
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
    , "new", .resolution, "6:20 this reference would refer to another `new` declared closer to it");
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
