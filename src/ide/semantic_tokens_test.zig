const std = @import("std");
const testing = std.testing;
const World = @import("../names/resolve_test.zig").World;
const resolve = @import("../names/resolve.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const offsets = @import("../util/offsets.zig");
const types = @import("../lsp/types.zig");
const semantic = @import("semantic_tokens.zig");
const T = semantic.TokenType;
const M = semantic.Modifier;

fn tokens(w: *World, file: FileId, text: []const u8, enc: offsets.Encoding, range: ?types.Range) ![]const u32 {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    return semantic.semanticTokens(&r, file, lines, enc, range);
}

const Case = struct {
    needle: []const u8,
    nth: usize = 0,
    ty: T,
    mods: u32 = 0,
    len: ?u32 = null,
};

fn check(data: []const u32, text: []const u8, enc: offsets.Encoding, cases: []const Case) !void {
    try testing.expectEqual(@as(usize, 0), data.len % 5);
    for (cases) |case| {
        var offset: usize = 0;
        for (0..case.nth) |_| offset = (std.mem.indexOfPos(u8, text, offset, case.needle) orelse return error.MissingNeedle) + 1;
        offset = std.mem.indexOfPos(u8, text, offset, case.needle) orelse return error.MissingNeedle;
        const expected = offsets.offsetToPosition(text, offset, enc);
        var pos: types.Position = .{ .line = 0, .character = 0 };
        var found = false;
        var i: usize = 0;
        while (i < data.len) : (i += 5) {
            if (data[i] != 0) pos.character = 0;
            pos.line += data[i];
            pos.character += data[i + 1];
            if (!std.meta.eql(pos, expected)) continue;
            found = true;
            testing.expectEqual(@backingInt(case.ty), data[i + 3]) catch |err| {
                std.debug.print("semantic token `{s}`: expected {t}, got {d}\n", .{ case.needle, case.ty, data[i + 3] });
                return err;
            };
            try testing.expectEqual(case.mods, data[i + 4]);
            if (case.len) |len| try testing.expectEqual(len, data[i + 2]);
            break;
        }
        if (!found) {
            std.debug.print("missing semantic token `{s}` at {d}:{d}\n", .{ case.needle, expected.line, expected.character });
            return error.MissingSemanticToken;
        }
    }
}

test "semantic tokens resolve declarations references aliases and imported members" {
    const text =
        \\const dep = @import("dep.zig");
        \\const Alias = dep.lower;
        \\const number = u32;
        \\const E = enum { first, second };
        \\const U = union(enum) { first: u32, second: void };
        \\fn run(arg: number) void {
        \\    var local = arg;
        \\    const instance: Alias = .{ .value = arg };
        \\    local += instance.method();
        \\    _ = dep.answer;
        \\    _ = dep.helper();
        \\    _ = E.first;
        \\    _ = U;
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/dep.zig",
        \\pub const answer = 42;
        \\pub const lower = struct {
        \\    value: u32,
        \\    pub fn method(self: lower) u32 { return self.value; }
        \\};
        \\pub fn helper() void {}
    );
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "dep =", .ty = .namespace, .mods = M.declaration | M.readonly },
        .{ .needle = "Alias =", .ty = .@"struct", .mods = M.declaration | M.readonly },
        .{ .needle = "dep.lower", .ty = .namespace, .mods = M.readonly },
        .{ .needle = "lower;", .ty = .@"struct", .mods = M.readonly },
        .{ .needle = "number =", .ty = .type, .mods = M.declaration | M.readonly },
        .{ .needle = "number)", .ty = .type, .mods = M.readonly },
        .{ .needle = "E =", .ty = .@"enum", .mods = M.declaration | M.readonly },
        .{ .needle = "first,", .ty = .enumMember, .mods = M.declaration },
        .{ .needle = "U =", .ty = .type, .mods = M.declaration | M.readonly },
        .{ .needle = "first:", .ty = .property, .mods = M.declaration },
        .{ .needle = "arg:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "arg;", .ty = .parameter, .mods = M.readonly },
        .{ .needle = "local =", .ty = .variable, .mods = M.declaration },
        .{ .needle = "local +=", .ty = .variable },
        .{ .needle = "instance:", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "Alias = .", .ty = .@"struct", .mods = M.readonly },
        .{ .needle = "value =", .ty = .property },
        .{ .needle = "instance.method", .ty = .variable, .mods = M.readonly },
        .{ .needle = "method()", .ty = .method },
        .{ .needle = "answer;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "helper()", .ty = .function },
        .{ .needle = "E.first", .ty = .@"enum", .mods = M.readonly },
        .{ .needle = "first;", .ty = .enumMember },
        .{ .needle = "U;", .ty = .type, .mods = M.readonly },
    });
}

test "semantic tokens respect lexical shadowing captures and labels" {
    const text =
        \\const value = 1;
        \\fn run(value: ?u32) void {
        \\    if (value) |payload| {
        \\        const value = payload;
        \\        _ = value;
        \\    }
        \\    var mutable: u32 = 0;
        \\    { const mutable = 2; _ = mutable; }
        \\    _ = mutable;
        \\    const result = blk: { break :blk 1; };
        \\    for ([_]u32{result}) |entry| { _ = entry; }
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "value:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "value)", .ty = .parameter, .mods = M.readonly },
        .{ .needle = "payload|", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "payload;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "value = payload", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "value;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "mutable:", .ty = .variable, .mods = M.declaration },
        .{ .needle = "mutable =", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "mutable;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "mutable;", .nth = 1, .ty = .variable },
        .{ .needle = "blk:", .ty = .label, .mods = M.declaration },
        .{ .needle = "blk 1", .ty = .label },
        .{ .needle = "entry|", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "entry;", .ty = .variable, .mods = M.readonly },
    });
}

test "semantic tokens distinguish methods function fields and callable aliases" {
    const text =
        \\fn add(a: u32) u32 { return a; }
        \\const callback = add;
        \\const S = struct {
        \\    invoke: *const fn (u32) u32,
        \\    fn method(self: S) u32 { return self.invoke(1); }
        \\};
        \\fn run() void {
        \\    const s: S = .{ .invoke = callback };
        \\    const local = add;
        \\    _ = s.invoke(local(1));
        \\    _ = s.method();
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "add(a", .ty = .function, .mods = M.declaration },
        .{ .needle = "callback =", .ty = .function, .mods = M.declaration | M.readonly },
        .{ .needle = "add;", .ty = .function },
        .{ .needle = "invoke:", .ty = .property, .mods = M.declaration },
        .{ .needle = "method(self", .ty = .method, .mods = M.declaration },
        .{ .needle = "invoke(1)", .ty = .property },
        .{ .needle = "invoke =", .ty = .property },
        .{ .needle = "callback }", .ty = .function, .mods = M.readonly },
        .{ .needle = "local =", .ty = .function, .mods = M.declaration | M.readonly },
        .{ .needle = "invoke(local", .ty = .property },
        .{ .needle = "local(1)", .ty = .function, .mods = M.readonly },
        .{ .needle = "method()", .ty = .method },
    });
}

test "semantic tokens identify generic type parameters and seeded members" {
    const text =
        \\const lower = struct { fn method(self: lower) u32 { _ = self; return 1; } };
        \\fn generic(comptime T: type, arg: T) T { return arg; }
        \\fn invoke(value: anytype) u32 { return value.method(); }
        \\fn run() void { _ = generic(u32, 1); _ = invoke(lower{}); }
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "T:", .ty = .typeParameter, .mods = M.declaration | M.readonly },
        .{ .needle = "T)", .ty = .typeParameter, .mods = M.readonly },
        .{ .needle = "T {", .ty = .typeParameter, .mods = M.readonly },
        .{ .needle = "arg:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "arg;", .ty = .parameter, .mods = M.readonly },
        .{ .needle = "value.method", .ty = .parameter, .mods = M.readonly },
        .{ .needle = "method()", .ty = .method },
    });
}

test "semantic tokens preserve syntax for unresolved code and classify error members" {
    const text =
        \\/// Documentation
        \\const Errors = error{ Bad };
        \\const unresolved: Missing = unknown.field;
        \\fn run(arg: Missing) void {
        \\    const local = arg;
        \\    _ = local;
        \\    _ = Errors.Bad;
        \\    _ = error.Bad;
        \\    _ = @sizeOf(u32) + 1;
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "///", .ty = .comment, .mods = M.documentation },
        .{ .needle = "Errors =", .ty = .type, .mods = M.declaration | M.readonly },
        .{ .needle = "Bad }", .ty = .enumMember, .mods = M.declaration },
        .{ .needle = "unresolved:", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "unknown.field", .ty = .variable },
        .{ .needle = "field;", .ty = .property },
        .{ .needle = "arg;", .ty = .parameter, .mods = M.readonly },
        .{ .needle = "local;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "Bad;", .ty = .enumMember },
        .{ .needle = "Bad;", .nth = 1, .ty = .enumMember },
        .{ .needle = "@sizeOf", .ty = .function, .mods = M.defaultLibrary },
        .{ .needle = "u32)", .ty = .type, .mods = M.defaultLibrary },
        .{ .needle = "+ 1", .ty = .operator },
    });
}

test "semantic token ranges preserve whole unicode tokens and document relative deltas" {
    const text = "const @\"😀a\" = 1;\r\nfn run() void { _ = @\"😀a\"; }\r\n";
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    for ([_]offsets.Encoding{ .utf8, .utf16, .utf32 }, [_]u32{ 8, 6, 5 }) |enc, width| {
        const data = try tokens(&w, file, text, enc, null);
        const cases = [_]Case{
            .{ .needle = "@\"😀a\"", .ty = .variable, .mods = M.declaration | M.readonly, .len = width },
            .{ .needle = "@\"😀a\"", .nth = 1, .ty = .variable, .mods = M.readonly, .len = width },
        };
        try check(data, text, enc, &cases);
        const offset = std.mem.lastIndexOf(u8, text, "@\"😀a\"").?;
        const start = offsets.offsetToPosition(text, offset, enc);
        const partial: types.Range = .{
            .start = .{ .line = start.line, .character = start.character + 1 },
            .end = .{ .line = start.line, .character = start.character + 2 },
        };
        const ranged = try tokens(&w, file, text, enc, partial);
        try testing.expectEqual(@as(usize, 5), ranged.len);
        try check(ranged, text, enc, cases[1..]);
        try testing.expectEqual(start.line, ranged[0]);
        try testing.expectEqual(start.character, ranged[1]);
        const empty = try tokens(&w, file, text, enc, .{ .start = start, .end = start });
        try testing.expectEqual(@as(usize, 0), empty.len);
        const touching = try tokens(&w, file, text, enc, .{
            .start = .{ .line = start.line, .character = start.character - 1 },
            .end = start,
        });
        try testing.expectEqual(@as(usize, 0), touching.len);
        const after: types.Position = .{ .line = start.line, .character = start.character + width };
        const excluded = try tokens(&w, file, text, enc, .{
            .start = after,
            .end = .{ .line = after.line, .character = after.character + 1 },
        });
        try testing.expectEqual(@as(usize, 0), excluded.len);
    }
}

test "semantic tokens resolve module namespaces and declaration literals" {
    const text =
        \\const module = @import("package");
        \\const Alias = module.S;
        \\const chosen: Alias = .origin;
        \\const made: Alias = .init();
        \\fn run() void { _ = module.answer; _ = chosen; _ = made; }
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const lib = (try w.add("/pkg/lib.zig",
        \\pub const answer = 1;
        \\pub const S = struct {
        \\    pub const origin: S = .{};
        \\    pub fn init() S { return .{}; }
        \\};
    )).file;
    const file = (try w.add("/p/main.zig", text)).file;
    try w.setGraph(null, &.{
        .{ .root = file, .imports = &.{.{ .name = "package", .module = 1 }} },
        .{ .root = lib, .imports = &.{} },
    }, &.{
        .{ .file = file, .module = 0, .root_module = 0 },
        .{ .file = lib, .module = 1, .root_module = 0 },
    });
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "module =", .ty = .namespace, .mods = M.declaration | M.readonly },
        .{ .needle = "module.S", .ty = .namespace, .mods = M.readonly },
        .{ .needle = "S;", .ty = .@"struct", .mods = M.readonly },
        .{ .needle = "Alias =", .ty = .@"struct", .mods = M.declaration | M.readonly },
        .{ .needle = "Alias = .origin", .ty = .@"struct", .mods = M.readonly },
        .{ .needle = "origin;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "init()", .ty = .function },
        .{ .needle = "answer;", .ty = .variable, .mods = M.readonly },
    });
}

test "semantic tokens mark only unused lexical bindings without confusing shadowing" {
    const text =
        \\pub const exported = 1;
        \\const private = 2;
        \\fn run(used: u32, unused: u32, opt: ?u32) void {
        \\    _ = used;
        \\    const lost = 1;
        \\    const shadow = 1;
        \\    { const shadow = 2; _ = shadow; }
        \\    var written: u32 = 0;
        \\    written = 1;
        \\    if (opt) |payload| {}
        \\    const _ = 3;
        \\}
        \\fn generic(comptime Unused: type) void {}
        \\fn outer() type {
        \\    const captured = u32;
        \\    return struct { value: captured };
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "exported =", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "private =", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "used:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "unused:", .ty = .parameter, .mods = M.declaration | M.readonly | M.unused },
        .{ .needle = "opt:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "lost =", .ty = .variable, .mods = M.declaration | M.readonly | M.unused },
        .{ .needle = "shadow =", .ty = .variable, .mods = M.declaration | M.readonly | M.unused },
        .{ .needle = "shadow =", .nth = 1, .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "written:", .ty = .variable, .mods = M.declaration },
        .{ .needle = "payload|", .ty = .variable, .mods = M.declaration | M.readonly | M.unused },
        .{ .needle = "Unused:", .ty = .typeParameter, .mods = M.declaration | M.readonly | M.unused },
        .{ .needle = "captured =", .ty = .type, .mods = M.declaration | M.readonly },
    });
}

test "semantic unused modifiers update when references are inserted and removed" {
    const unused = "fn run() void { const local = 1; }";
    const used = "fn run() void { const local = 1; _ = local; }";
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    for ([_][]const u8{ unused, used, unused }, [_]bool{ true, false, true }) |text, is_unused| {
        const file = (try w.add("/p/main.zig", text)).file;
        const data = try tokens(&w, file, text, .utf16, null);
        try check(data, text, .utf16, &.{.{
            .needle = "local =",
            .ty = .variable,
            .mods = M.declaration | M.readonly | (if (is_unused) M.unused else @as(u32, 0)),
        }});
    }
}

test "semantic tokens resolve escaped primitive names before builtin fallback" {
    const text =
        \\fn run(@"u32": u32) void {
        \\    const @"true" = 1;
        \\    const @"\x75\x73\x69\x7a\x65" = 2;
        \\    _ = @"u32";
        \\    _ = @"true";
        \\    _ = @"usize";
        \\}
        \\fn outer() type {
        \\    const @"bool" = u32;
        \\    return struct { value: @"bool" };
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "@\"u32\":", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "@\"u32\";", .ty = .parameter, .mods = M.readonly },
        .{ .needle = "@\"true\" =", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "@\"true\";", .ty = .variable, .mods = M.readonly },
        .{ .needle = "@\"\\x75\\x73\\x69\\x7a\\x65\"", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "@\"usize\";", .ty = .variable, .mods = M.readonly },
        .{ .needle = "@\"bool\" =", .ty = .type, .mods = M.declaration | M.readonly },
        .{ .needle = "@\"bool\" }", .ty = .type, .mods = M.readonly },
    });
}

test "semantic tokens distinguish static container functions from typed receivers" {
    const text =
        \\const S = struct {
        \\    const Self = @This();
        \\    fn init() S { return .{}; }
        \\    fn helper(value: u32) u32 { return value; }
        \\    fn method(self: *const Self) void { _ = self; }
        \\};
        \\const make = S.init;
        \\fn run() void {
        \\    const s = make();
        \\    _ = S.helper(1);
        \\    s.method();
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "init()", .ty = .function, .mods = M.declaration },
        .{ .needle = "helper(value", .ty = .function, .mods = M.declaration },
        .{ .needle = "method(self", .ty = .method, .mods = M.declaration },
        .{ .needle = "make =", .ty = .function, .mods = M.declaration | M.readonly },
        .{ .needle = "init;", .ty = .function },
        .{ .needle = "helper(1)", .ty = .function },
        .{ .needle = "method()", .ty = .method },
    });
}

test "semantic tokens do not infer unused parameters from bodyless declarations" {
    const text =
        \\extern fn native(arg: u32) void;
        \\fn incomplete(value: u32) void;
        \\fn implemented(unused: u32) void {}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "arg:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "value:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "unused:", .ty = .parameter, .mods = M.declaration | M.readonly | M.unused },
    });
}

test "semantic tokens count asm output targets without treating operand labels as uses" {
    const text =
        \\fn run(input: usize) void {
        \\    var output: usize = 0;
        \\    const label = 1;
        \\    const Result = usize;
        \\    asm volatile ("" : [label] "=r" (output) : [input] "r" (input));
        \\    _ = asm ("" : [output] "=r" (-> Result));
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "input:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "output:", .ty = .variable, .mods = M.declaration },
        .{ .needle = "label =", .ty = .variable, .mods = M.declaration | M.readonly | M.unused },
        .{ .needle = "Result =", .ty = .type, .mods = M.declaration | M.readonly },
        .{ .needle = "output)", .ty = .variable },
        .{ .needle = "input)", .ty = .parameter, .mods = M.readonly },
        .{ .needle = "Result)", .ty = .type, .mods = M.readonly },
    });
}

test "semantic tokens validate closed error and generated enum members" {
    const text =
        \\const Errors = error{ Valid };
        \\const U = union(enum) { valid: u32 };
        \\const Tag = @typeInfo(U).@"union".tag_type.?;
        \\fn run() void {
        \\    _ = Errors.Valid;
        \\    _ = Errors.Missing;
        \\    _ = Tag.valid;
        \\    _ = Tag.missing;
        \\    _ = anyerror.Other;
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var env = try @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null);
    defer env.deinit(testing.allocator);
    const std_root_path = try std.fs.path.join(testing.allocator, &.{ env.std_dir, "std.zig" });
    defer testing.allocator.free(std_root_path);
    try w.setGraph(try w.vfs.intern(std_root_path), &.{}, &.{});
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "Valid;", .ty = .enumMember },
        .{ .needle = "Missing;", .ty = .property },
        .{ .needle = "valid;", .ty = .enumMember },
        .{ .needle = "missing;", .ty = .property },
        .{ .needle = "Other;", .ty = .enumMember },
    });
}

test "semantic unused tracking preserves lexical uses in unselected generic branches" {
    const text =
        \\fn choose(comptime T: type, input: T, alternate: T) T {
        \\    if (T == u32) return input;
        \\    defer { _ = alternate; }
        \\    return alternate;
        \\}
        \\fn run() void { _ = choose(u32, 1, 2); }
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "T:", .ty = .typeParameter, .mods = M.declaration | M.readonly },
        .{ .needle = "input:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "alternate:", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "alternate;", .ty = .parameter, .mods = M.readonly },
    });
}

test "semantic tokens distinguish quoted underscore bindings from bare discards" {
    const text =
        \\fn used() void {
        \\    const @"_" = 1;
        \\    const _ = 2;
        \\    _ = (@"_");
        \\}
        \\fn unused() void {
        \\    const @"_" = 1;
        \\    _ = 2;
        \\}
        \\fn captured(@"_": u32) void { _ = @"_"; }
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "@\"_\" =", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "@\"_\")", .ty = .variable, .mods = M.readonly },
        .{ .needle = "@\"_\" =", .nth = 1, .ty = .variable, .mods = M.declaration | M.readonly | M.unused },
        .{ .needle = "@\"_\":", .ty = .parameter, .mods = M.declaration | M.readonly },
        .{ .needle = "@\"_\";", .ty = .parameter, .mods = M.readonly },
    });
}

test "semantic tokens retain lexical uses in captures deferred blocks and loop continuations" {
    const text =
        \\fn run(fallible: anyerror!u32, values: []u32) void {
        \\    const deferred = 1;
        \\    defer { _ = deferred; }
        \\    errdefer |failure| { _ = failure; }
        \\    const value = fallible catch |caught| { _ = caught; return; };
        \\    switch (value) { 0 => {}, else => |tag| { _ = tag; } }
        \\    for (values) |*entry| { entry.* = 0; }
        \\    var count: usize = 0;
        \\    while (false) : (count += 1) {}
        \\    const first, var second = .{ 1, 2 };
        \\    comptime { _ = first; }
        \\    second = 3;
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "deferred =", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "failure|", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "failure;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "caught|", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "caught;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "tag|", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "tag;", .ty = .variable, .mods = M.readonly },
        .{ .needle = "entry|", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "entry.*", .ty = .variable, .mods = M.readonly },
        .{ .needle = "count:", .ty = .variable, .mods = M.declaration },
        .{ .needle = "first,", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "second =", .ty = .variable, .mods = M.declaration },
    });
}

test "semantic tokens distinguish bare primitives from escaped names and unresolved escaped primitives" {
    const text =
        \\const @"usize" = 1;
        \\fn probe(@"u32": u32) u32 {
        \\    const local: u32 = @"u32";
        \\    _ = @"usize";
        \\    _ = local;
        \\    return @"u32";
        \\}
        \\fn unresolved() void { _ = @"bool"; }
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "u32)", .ty = .type, .mods = M.defaultLibrary },
        .{ .needle = "u32 {", .ty = .type, .mods = M.defaultLibrary },
        .{ .needle = "u32 =", .ty = .type, .mods = M.defaultLibrary },
        .{ .needle = "@\"u32\";", .ty = .parameter, .mods = M.readonly },
        .{ .needle = "@\"u32\";", .nth = 1, .ty = .parameter, .mods = M.readonly },
        .{ .needle = "@\"usize\";", .ty = .variable, .mods = M.readonly },
        .{ .needle = "@\"bool\";", .ty = .variable },
    });
}

test "semantic tokens infer escaped primitive bindings through comptime calls and member access" {
    const text =
        \\fn Build() type {
        \\    const @"u32" = struct {
        \\        value: u8,
        \\        fn method(self: @This()) u8 { return self.value; }
        \\    };
        \\    return @"u32";
        \\}
        \\const Built = Build();
        \\fn run() void {
        \\    const @"usize": Built = .{ .value = 1 };
        \\    _ = @"usize".method();
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const data = try tokens(&w, file, text, .utf16, null);
    try check(data, text, .utf16, &.{
        .{ .needle = "Built =", .ty = .@"struct", .mods = M.declaration | M.readonly },
        .{ .needle = "Built = .", .ty = .@"struct", .mods = M.readonly },
        .{ .needle = "@\"usize\":", .ty = .variable, .mods = M.declaration | M.readonly },
        .{ .needle = "@\"usize\".method", .ty = .variable, .mods = M.readonly },
        .{ .needle = "method()", .ty = .method },
    });
}
