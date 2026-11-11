//! IDE feature tests that depend on type inference (in-memory projects).

const std = @import("std");
const testing = std.testing;
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;
const database = @import("../database.zig");
const hover = @import("hover.zig");
const completion = @import("completion.zig");
const definition = @import("definition.zig");
const signature_help = @import("signature_help.zig");
const inlay_hints = @import("inlay_hints.zig");
const inactive = @import("inactive.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const Vfs = @import("../base/Vfs.zig");
const test_path = @import("../util/test_path.zig");
const seed = database.ide_db.seed;
const search = @import("../ide_db/search.zig");

const src =
    \\/// A point in the plane
    \\const Point = struct {
    \\    x: i32,
    \\    y: i32 = 0,
    \\    pub const origin: Point = .{ .x = 0 };
    \\    pub fn init(x: i32, y: i32) Point { return .{ .x = x, .y = y }; }
    \\    /// Distance to the origin
    \\    pub fn dist(self: Point, scale: u32) u32 { _ = .{ self, scale }; return 0; }
    \\};
    \\fn add(a: u32, b: u32) u32 { return a + b; }
    \\fn run(ptr: *Point, buf: []u8) void {
    \\    const p: Point = .init(1, 2);
    \\    const d = p.dist(3);
    \\    const sum = add(d, 1);
    \\    const o: Point = .origin;
    \\    _ = .{ ptr.x, buf.len, sum, o };
    \\}
    \\
;

fn setup(w: *World) !FileId {
    try w.init();
    return (try w.add("/p/main.zig", src)).file;
}

fn offsetOf(needle: []const u8, nth: usize) u32 {
    var start: usize = 0;
    for (0..nth) |_| start = std.mem.indexOfPos(u8, src, start, needle).? + 1;
    return @intCast(std.mem.indexOfPos(u8, src, start, needle).?);
}

fn resolver(w: *World, ctx: *database.Db.Ctx) resolve.Resolver {
    return .{ .ctx = ctx, .arena = w.arena.allocator() };
}

test "hover shows signature, type and doc" {
    var w: World = undefined;
    const file = try setup(&w);
    defer w.deinit();
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "d = p", 0, "```zig\nconst d: u32\n```" },
        .{ "dist(3)", 0, "```zig\npub fn dist(self: Point, scale: u32) u32\n```\n\nDistance to the origin" },
        .{ "Point", 0, "```zig\nconst Point = struct\n```\n\nA point in the plane" },
        .{ "x, buf", 0, "```zig\nx: i32\n```" },
        .{ "ptr: *Point", 0, "```zig\nptr: *Point\n```" },
        .{ "init(1", 0, "```zig\npub fn init(x: i32, y: i32) Point\n```" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, offsetOf(c[0], c[1]), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[2], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

/// The hover text at the character before the cursor and the doc of the completion item `label` at
/// the cursor (both owned by the caller)
fn importedDocs(source: []const u8, label: []const u8) ![2][]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(source);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    const info = try hover.hover(&r, at.file, at.offset - 1, &.{}, .list) orelse return error.NoHover;
    const item = for ((try completion.complete(&r, at.file, at.offset, .{ .auto_import = false })).items) |it| {
        if (std.mem.eql(u8, it.label, label)) break it;
    } else return error.NoItem;
    return .{ try testing.allocator.dupe(u8, info.text), try testing.allocator.dupe(u8, item.doc orelse "") };
}

test "hover and completion on a constant that imports a file show the file's doc" {
    const cases = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        // A top-level constant importing a file
        .{
            \\//- /p/main.zig
            \\const worker_stack = @import("util/worker_stack.zig");
            \\fn run() void {
            \\    _ = worker_stack<|>;
            \\}
            \\//- /p/util/worker_stack.zig
            \\//! A stack of workers.
            \\//! Second line.
            \\pub const max = 4;
            ,
            "worker_stack",
            "```zig\nconst worker_stack: type = worker_stack\n```\n\nA stack of workers.\nSecond line.",
            "A stack of workers.\nSecond line.",
        },
        // The declaration's own doc comes before the file's
        .{
            \\//- /p/main.zig
            \\/// Imported here.
            \\const ws = @import("ws.zig");
            \\fn run() void {
            \\    _ = ws<|>;
            \\}
            \\//- /p/ws.zig
            \\//! Workers.
            \\pub const max = 4;
            ,
            "ws",
            "```zig\nconst ws: type = ws\n```\n\nImported here.\n\nWorkers.",
            "Imported here.\n\nWorkers.",
        },
        // A local constant importing a file
        .{
            \\//- /p/main.zig
            \\fn run() void {
            \\    const ws = @import("ws.zig");
            \\    _ = ws<|>;
            \\}
            \\//- /p/ws.zig
            \\//! Workers.
            \\pub const max = 4;
            ,
            "ws",
            "```zig\nconst ws: type = ws\n```\n\nWorkers.",
            "Workers.",
        },
        // `@This()` at the top level is the file itself: the doc of the file it is in
        .{
            \\//- /p/ws.zig
            \\//! Workers.
            \\const Self = @This();
            \\fn run() void {
            \\    _ = Self<|>;
            \\}
            ,
            "Self",
            "```zig\nconst Self: type = ws\n```\n\nWorkers.",
            "Workers.",
        },
    };
    for (cases) |c| {
        const docs = try importedDocs(c[0], c[1]);
        defer for (docs) |d| testing.allocator.free(d);
        testing.expectEqualStrings(c[2], docs[0]) catch |err| {
            std.debug.print("hover in\n{s}\n", .{c[0]});
            return err;
        };
        try testing.expectEqualStrings(c[3], docs[1]);
    }
}

test "hover on field names in initializers shows the field" {
    // Prevents a null hover on `.name` in `.{ .name = x }` while goto resolves the field
    const text =
        \\const Opts = struct {
        \\    /// Name of the thing.
        \\    name: []const u8,
        \\    inner: Inner = .{},
        \\};
        \\const Inner = struct { depth: u8 = 0 };
        \\const U = union { a: u32, b: bool };
        \\fn Pair(comptime T: type) type {
        \\    return struct { first: T, second: T };
        \\}
        \\fn make(o: Opts) Opts {
        \\    return o;
        \\}
        \\fn generic(comptime T: type) Pair(T) {
        \\    return .{ .first = undefined, .second = undefined };
        \\}
        \\pub fn main() void {
        \\    const a: Opts = .{ .name = "a" };
        \\    const b = Opts{ .name = "b" };
        \\    const c = make(.{ .name = "c", .inner = .{ .depth = 2 } });
        \\    var d: Opts = undefined;
        \\    d = .{ .name = "d" };
        \\    const u: U = .{ .a = 3 };
        \\    const p: Pair(u32) = .{ .first = 1, .second = 2 };
        \\    _ = .{ a, b, c, d, u, p, a.name, generic(u16) };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const name = "```zig\nname: []const u8\n```\n\nName of the thing.";
    const control = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "name, generic").?), &.{}, .list)).?;
    try testing.expectEqualStrings(name, control.text);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "name = \"a\"", name },
        .{ "name = \"b\"", name },
        .{ "name = \"c\"", name },
        .{ "name = \"d\"", name },
        .{ "inner = .{ .depth", "```zig\ninner: Inner\n```" },
        .{ "depth = 2", "```zig\ndepth: u8\n```" },
        .{ "a = 3", "```zig\na: u32\n```" },
        // The field type in the instance
        .{ "first = 1", "```zig\nfirst: u32\n```" },
        .{ "second = 2", "```zig\nsecond: u32\n```" },
        // Inside a generic function, the field type in terms of its parameters
        .{ "first = undefined", "```zig\nfirst: T\n```" },
    };
    for (cases) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list)) orelse {
            std.debug.print("no hover at `{s}`\n", .{c[0]});
            return error.NoHover;
        };
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "hover on field names of build.zig option structs" {
    const text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }) });
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/build.zig", text)).file;
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "name = ", "```zig\nname: []const u8\n```" },
        .{ "root_module", "```zig\nroot_module: *Module\n```" },
        .{ "root_source_file", "```zig\nroot_source_file: ?LazyPath\n```\n\nThis could either be a generated file" },
    };
    for (cases) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list)) orelse {
            std.debug.print("no hover at `{s}`\n", .{c[0]});
            return error.NoHover;
        };
        testing.expect(std.mem.startsWith(u8, info.text, c[1])) catch |err| {
            std.debug.print("hover at `{s}`: {s}\n", .{ c[0], info.text });
            return err;
        };
    }
}

test "member completion and goto definition through types" {
    var w: World = undefined;
    const file = try setup(&w);
    defer w.deinit();
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    // After `ptr.` (through a pointer): fields and methods
    const items = (try completion.complete(&r, file, offsetOf("ptr.x", 0) + 4, .{ .auto_import = false })).items;
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    try testing.expectEqualStrings("x y dist", try std.mem.join(w.arena.allocator(), " ", labels.items));
    try testing.expectEqualStrings("i32", items[0].detail.?);
    // Slices
    const slice_items = (try completion.complete(&r, file, offsetOf("buf.len", 0) + 4, .{ .auto_import = false })).items;
    try testing.expectEqualStrings("len", slice_items[0].label);

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "x, buf", "    x: i32" },
        .{ "dist(3)", "    pub fn dist" },
        .{ "init(1", "    pub fn init" },
        .{ "origin;", "    pub const origin" },
    };
    for (cases) |c| {
        const t = try definition.definition(&r, file, offsetOf(c[0], 0)) orelse return error.NoDefinition;
        const line_start = std.mem.lastIndexOfScalar(u8, src[0..t.start], '\n').? + 1;
        testing.expect(std.mem.startsWith(u8, src[line_start..], c[1])) catch |err| {
            std.debug.print("goto `{s}` landed on: {s}\n", .{ c[0], src[line_start..t.end] });
            return err;
        };
    }
}

test "decltest identifier is a reference to the declaration" {
    const text =
        \\fn helper(x: u32) u32 {
        \\    return x + 1;
        \\}
        \\test helper {
        \\    const y = helper(1);
        \\    _ = y;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);

    const test_name: u32 = @intCast(std.mem.indexOf(u8, text, "test helper").? + "test ".len);
    const t = (try definition.definition(&r, file, test_name)) orelse return error.NoTarget;
    try testing.expectEqual(file, t.file);
    try testing.expect(std.mem.startsWith(u8, text[t.start..], "helper(x: u32)"));

    const info = (try hover.hover(&r, file, test_name, &.{}, .list)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nfn helper(x: u32) u32\n```", info.text);

    const fn_name: u32 = @intCast(std.mem.indexOf(u8, text, "fn helper").? + "fn ".len);
    const def = (try definition.defAt(&r, file, fn_name)) orelse return error.NoDefinition;
    const refs = try search.findReferences(&r, def, .{ .scope = &.{file} });
    var saw_test = false;
    var saw_call = false;
    for (refs) |ref| {
        if (ref.start == test_name) saw_test = true;
        if (ref.start == std.mem.indexOf(u8, text, "helper(1)").?) saw_call = true;
    }
    try testing.expect(saw_test);
    try testing.expect(saw_call);
    try testing.expectEqual(3, refs.len);
}

test "definition of bare primitive names skips escaped declarations" {
    const text =
        \\pub fn escaped(@"u32": u32) u32 {
        \\    const local: u32 = @"u32";
        \\    return local;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);

    // A bare `u32` is the primitive type and must not resolve to the escaped parameter of the same
    // name
    const bare = std.mem.indexOf(u8, text, "local: u32").? + "local: ".len;
    try testing.expectEqual(null, try definition.definition(&r, file, @intCast(bare)));

    // An escaped reference still resolves to the parameter
    const quoted = std.mem.indexOf(u8, text, "= @\"u32\"").? + 4;
    const t = (try definition.definition(&r, file, @intCast(quoted))) orelse return error.NoTarget;
    try testing.expectEqual(file, t.file);
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "@\"u32\"").?)), t.start);
}

test "completion and hover quote names that shadow primitives or are not identifiers" {
    const text =
        \\pub const @"bool" = c_int;
        \\fn f(@"i32": u8) u8 {
        \\    const @"a b" = @"i32";
        \\    _ = @"a b";
        \\    _ = <|>;
        \\    return @"i32";
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    const marker = std.mem.indexOf(u8, text, "<|>").?;
    const clean = try std.mem.concat(w.arena.allocator(), u8, &.{ text[0..marker], text[marker + 3 ..] });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);

    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    var saw = [4]bool{ false, false, false, false };
    const expected = [_][]const u8{ "@\"a b\"", "@\"i32\"", "@\"bool\"", "f" };
    for (items) |it| for (expected, 0..) |e, i| {
        if (std.mem.eql(u8, it.label, e)) saw[i] = true;
    };
    for (saw) |ok| try testing.expect(ok);

    const local = (try hover.hover(&r, added.file, @intCast(std.mem.indexOf(u8, clean, "_ = @\"a b\"").? + 6), &.{}, .list)).?;
    try testing.expectEqualStrings("```zig\nconst @\"a b\": u8\n```", local.text);
    const param = (try hover.hover(&r, added.file, @intCast(std.mem.indexOf(u8, clean, "return @\"i32\"").? + 8), &.{}, .list)).?;
    try testing.expectEqualStrings("```zig\n@\"i32\": u8\n```", param.text);
}

test "signature help and inlay hints" {
    var w: World = undefined;
    const file = try setup(&w);
    defer w.deinit();
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);

    const s = try signature_help.signatureHelp(&r, file, offsetOf("1);", 0)) orelse return error.NoSignature;
    try testing.expectEqualStrings("fn add(a: u32, b: u32) u32", s.label);
    try testing.expectEqual(1, s.active);
    try testing.expectEqualStrings("b: u32", s.params[1]);
    // Method call: self is skipped
    const m = try signature_help.signatureHelp(&r, file, offsetOf("3);", 0)) orelse return error.NoSignature;
    try testing.expectEqual(1, m.active);
    try testing.expectEqualStrings("Distance to the origin", m.doc.?);

    const hints = try inlay_hints.inlayHints(&r, file, 0, @intCast(src.len), .{});
    var out: std.ArrayList(u8) = .empty;
    for (hints) |h| {
        try out.appendSlice(w.arena.allocator(), h.label);
        try out.append(w.arena.allocator(), ' ');
    }
    // Field types of initializers; types of local variables; parameter names at call sites (omitted
    // when the argument has the same name as the parameter, and for `p.dist(3)`, which has only one
    // argument)
    try testing.expectEqualStrings(": i32 : i32 : i32 x: y: : u32 : u32 a: b: ", out.items);
}

test "calls through function fields are not method calls" {
    const text =
        \\fn add(a: i32, b: i32) i32 { return a + b; }
        \\const S = struct { g: fn (x: i32, y: i32) i32 };
        \\const s: S = .{ .g = add };
        \\fn caller() i32 {
        \\    return s.g(3, 4);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = struct {
        fn of(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, text, needle).?);
        }
    }.of;
    // A function in a field does not bind a receiver: the first argument corresponds to a
    const sig = (try signature_help.signatureHelp(&r, file, at("3, 4"))).?;
    try testing.expectEqualStrings("fn add(a: i32, b: i32) i32", sig.label);
    try testing.expectEqual(0, sig.active);
    const hints = try inlay_hints.inlayHints(&r, file, 0, @intCast(text.len), .{});
    var out: std.ArrayList(u8) = .empty;
    for (hints) |h| if (h.kind == .parameter) {
        try out.appendSlice(w.arena.allocator(), h.label);
        try out.append(w.arena.allocator(), ' ');
    };
    try testing.expectEqualStrings("a: b: ", out.items);
}

test "signature help and parameter hints through function-typed values" {
    // Prevents calls through function pointers, vtable fields, callbacks and comptime function
    // parameters from getting no signature and no parameter names
    const text =
        \\fn add2(first: u32, second: u32) u32 { return first + second; }
        \\fn double(x: u8) u8 { return x * 2; }
        \\const Call2Op = *const fn (a: i8, b: i8) i8;
        \\fn doOp(fnCall: Call2Op, op1: i8, op2: i8) i8 { return fnCall(op1, op2); }
        \\const T = struct { run: *const fn (first: u32, second: u32) u32 };
        \\const VTable = struct {
        \\    /// Allocates `len` bytes.
        \\    alloc: *const fn (ctx: *anyopaque, len: usize, alignment: u8) ?[*]u8,
        \\};
        \\const Obj = struct {
        \\    ptr: *anyopaque,
        \\    vtable: *const VTable,
        \\    on_done: ?*const fn (code: u8, msg: []const u8) void,
        \\};
        \\fn apply(comptime f: fn (value: u8) u8, x: u8) u8 { return f(x); }
        \\fn use(o: Obj, t: T) void {
        \\    _ = t.run(1, 21);
        \\    const ptr = &add2;
        \\    _ = ptr(1, 22);
        \\    _ = o.vtable.alloc(o.ptr, 1, 8);
        \\    if (o.on_done) |cb| cb(31, "x");
        \\    const fp: *const fn (u8) u8 = &double;
        \\    _ = fp(32);
        \\    _ = apply(double, 33);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8, u32, ?[]const u8 }{
        .{ "op2); }", "fn (a: i8, b: i8) i8", 1, null },
        .{ "21);", "fn (first: u32, second: u32) u32", 1, null },
        .{ "22);", "fn add2(first: u32, second: u32) u32", 1, null },
        .{ "8);", "fn (ctx: *anyopaque, len: usize, alignment: u8) ?[*]u8", 2, "Allocates `len` bytes." },
        .{ "31,", "fn (code: u8, msg: []const u8) void", 0, null },
        .{ "32);", "fn (u8) u8", 0, null },
        .{ "x); }", "fn (value: u8) u8", 0, null },
    };
    for (cases) |c| {
        const s = (try signature_help.signatureHelp(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?))) orelse {
            std.debug.print("no signature at `{s}`\n", .{c[0]});
            return error.NoSignature;
        };
        testing.expectEqualStrings(c[1], s.label) catch |err| {
            std.debug.print("signature at `{s}`\n", .{c[0]});
            return err;
        };
        try testing.expectEqual(c[2], s.active);
        if (c[3]) |doc| try testing.expectEqualStrings(doc, s.doc.?);
    }
    const hints = try inlay_hints.inlayHints(&r, file, 0, @intCast(text.len), .{});
    var out: std.ArrayList(u8) = .empty;
    for (hints) |h| if (h.kind == .parameter) {
        try out.appendSlice(w.arena.allocator(), h.label);
        try out.append(w.arena.allocator(), ' ');
    };
    // `fnCall(op1, op2)`, `t.run`, `ptr`, `o.vtable.alloc` (`len` is the argument `1`), `cb`
    try testing.expectEqualStrings("a: b: first: second: first: second: ctx: len: alignment: code: msg: f: x: ", out.items);
}

test "signature help through the vtable of std.mem.Allocator" {
    const text =
        \\const std = @import("std");
        \\fn f(a: std.mem.Allocator) void {
        \\    _ = a.vtable.alloc(a.ptr, 1, .@"1", 0);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const s = (try signature_help.signatureHelp(&r, file, @intCast(std.mem.indexOf(u8, text, "0);").?))) orelse return error.NoSignature;
    try testing.expect(std.mem.startsWith(u8, s.label, "fn ("));
    try testing.expectEqual(4, s.params.len);
    try testing.expectEqual(3, s.active);
}

test "signature help keeps C-variadic arguments on the ... parameter" {
    // Prevents the active parameter from running past `...` from the second variadic argument on
    const text =
        \\extern fn printf(fmt: [*:0]const u8, ...) c_int;
        \\extern fn fcntl3(fd: c_int, cmd: c_int, ...) c_int;
        \\fn add(a: u32, b: u32) u32 { return a + b; }
        \\pub fn main() void {
        \\    const a: c_int = 1;
        \\    _ = printf("%d %d %d\n", a1, a2, a3);
        \\    _ = fcntl3(0, 1, a4, a5);
        \\    _ = add(1, 2, x3);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, u32 }{
        .{ "\"%d", 0 },
        .{ "a1", 1 },
        .{ "a2", 1 },
        .{ "a3", 1 },
        .{ "a4", 2 },
        .{ "a5", 2 },
        // Without `...` there is no parameter for an extra argument, and it is not clamped
        .{ "x3", 2 },
    };
    for (cases) |c| {
        const s = (try signature_help.signatureHelp(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?))) orelse return error.NoSignature;
        testing.expectEqual(c[1], s.active) catch |err| {
            std.debug.print("signature at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "signature help and parameter hints through aliases" {
    // Calls through an alias (`const assert = std.debug.assert;`): if the alias is not followed,
    // there is no signature help and there are no parameter name hints
    const text =
        \\fn add(a: u32, b: u32) u32 { return a + b; }
        \\const plus = add;
        \\const ns = struct { const sum = plus; };
        \\const S = struct {
        \\    fn addImpl(self: S, a: u32, b: u32) u32 { _ = self; return a + b; }
        \\    pub const sum = addImpl;
        \\};
        \\fn run(x: u32, s: S) void {
        \\    const local = add;
        \\    _ = plus(x, 1);
        \\    _ = ns.sum(x, 2);
        \\    _ = local(x, 3);
        \\    _ = s.sum(x, 4);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_][]const u8{ "1);", "2);", "3);" }) |needle| {
        const offset: u32 = @intCast(std.mem.indexOf(u8, text, needle).?);
        const s = try signature_help.signatureHelp(&r, file, offset) orelse return error.NoSignature;
        try testing.expectEqualStrings("fn add(a: u32, b: u32) u32", s.label);
        try testing.expectEqual(1, s.active);
    }
    // An alias of a method, called through a value, binds the receiver like the method itself
    const s = try signature_help.signatureHelp(&r, file, @intCast(std.mem.indexOf(u8, text, "4);").?)) orelse return error.NoSignature;
    try testing.expectEqualStrings("fn addImpl(self: S, a: u32, b: u32) u32", s.label);
    try testing.expectEqual(2, s.active);
    const hints = try inlay_hints.inlayHints(&r, file, 0, @intCast(text.len), .{});
    var out: std.ArrayList(u8) = .empty;
    for (hints) |h| if (h.kind == .parameter) {
        try out.appendSlice(w.arena.allocator(), h.label);
        try out.append(w.arena.allocator(), ' ');
    };
    try testing.expectEqualStrings("a: b: a: b: a: b: a: b: ", out.items);
}

test "hover and signature help drop comments from multi-line function prototypes" {
    // Prevents doc comments and trailing comments of parameters from being folded into the
    // signature, which makes the parameters after them look like comments
    const text =
        \\fn add(
        \\    /// the first
        \\    a: u32,
        \\    b: u32, // the second
        \\) callconv(.c) u32 { return a + b; }
        \\fn run() void {
        \\    _ = add(1, 2);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "add(1, 2)").?), &.{}, .list) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nfn add(a: u32, b: u32) callconv(.c) u32\n```", info.text);
    const s = try signature_help.signatureHelp(&r, file, @intCast(std.mem.indexOf(u8, text, "2);").?)) orelse return error.NoSignature;
    try testing.expectEqualStrings("fn add(a: u32, b: u32) callconv(.c) u32", s.label);
    try testing.expectEqualStrings("b: u32", s.params[1]);
}

test "name completion ranks scope names before namespace members, each by how well it matches" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const std = @import("std");
        \\const memo = 1;
        \\fn run(mem_param: u32) void {
        \\    const memory = 2;
        \\    _ = .{ memory, mem_param };
        \\    _ = mem<|>;
        \\}
        \\//- /zig/std/std.zig std
        \\pub const mem = struct { pub fn eql() void {} };
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    const items = try w.arena.allocator().dupe(completion.Item, (try completion.complete(&r, at.file, at.offset, .{})).items);
    std.mem.sort(completion.Item, items, {}, struct {
        fn less(_: void, a: completion.Item, b: completion.Item) bool {
            return std.mem.lessThan(u8, a.sort.?, b.sort.?);
        }
    }.less);
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    // Local names, parameters, container members and members through `std` come in that order;
    // names in scope that do not match sort last and are filtered by the client
    try testing.expectEqualStrings("memory mem_param memo std.mem std.mem.eql std run", try std.mem.join(w.arena.allocator(), " ", labels.items));
}

/// Labels of the candidates besides the names in scope (member paths of local values) given by name
/// completion without auto-import, sorted and joined by spaces
fn localMemberPaths(source: []const u8) ![]u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(source);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    var labels: std.ArrayList([]const u8) = .empty;
    for ((try completion.complete(&r, at.file, at.offset, .{ .auto_import = false })).items) |it| {
        if (it.weight == 0) try labels.append(w.arena.allocator(), it.label);
    }
    std.mem.sort([]const u8, labels.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return testing.allocator.dupe(u8, try std.mem.join(w.arena.allocator(), " ", labels.items));
}

test "name completion offers fields and callable methods of local values two levels deep" {
    const types =
        \\const Inner = struct {
        \\    depth: u32,
        \\    pub fn get(self: *const Inner) u32 { return self.depth; }
        \\    pub fn bump(self: *Inner) void { self.depth += 1; }
        \\    pub const peek = get;
        \\};
        \\const Outer = struct {
        \\    inner: Inner,
        \\    ptr: *Inner,
        \\    opt: ?Inner,
        \\    res: anyerror!Inner,
        \\    pub fn copy(self: Outer) Inner { return self.inner; }
        \\    pub fn view(self: *Outer) *Inner { return self.ptr; }
        \\    pub fn maybe(self: Outer) ?Inner { return self.opt; }
        \\    pub fn fallible(self: Outer) anyerror!Inner { return self.res; }
        \\    pub fn pick(self: Outer, n: u32) Inner { _ = n; return self.inner; }
        \\    pub fn make() Outer { return undefined; }
        \\};
        \\
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        // Fields and the results of methods that take only self and return a container or a
        // single-item pointer expand to a second level; `?T` and `E!T` values and methods with
        // parameters do not
        .{ "fn run(o: Outer) void { _ = o; _ = depth<|>; }", "o.copy().depth o.inner.depth o.ptr.depth" },
        // Methods receiving `*T` are offered only when the path can be modified (a local var, or
        // through a mutable pointer); a value returned by a method is a temporary that cannot be
        // modified
        .{ "fn run(o: Outer) void { _ = o; _ = bump<|>; }", "o.ptr.bump" },
        .{ "fn run() void { var o: Outer = undefined; _ = &o; _ = bump<|>; }", "o.inner.bump o.ptr.bump o.view().bump" },
        .{ "fn run(o: *Outer) void { _ = o; _ = bump<|>; }", "o.inner.bump o.ptr.bump o.view().bump" },
        .{ "fn run(o: *const Outer) void { _ = o; _ = bump<|>; }", "o.ptr.bump" },
        .{ "fn run(o: Outer) void { _ = o; _ = get<|>; }", "o.copy().get o.inner.get o.ptr.get" },
        // Methods with parameters are offered at the first level; a function whose first parameter
        // is not the enclosing container is not a method
        .{ "fn run(o: Outer) void { _ = o; _ = pick<|>; }", "o.pick" },
        .{ "fn run(o: Outer) void { _ = o; _ = make<|>; }", "" },
        // Pointers to pointers are not expanded
        .{ "fn run(o: **Outer) void { _ = o; _ = depth<|>; }", "" },
        // Local values that are types or whose types cannot be computed are not expanded
        .{ "fn run() void { const T = Outer; const u = missing(); _ = .{ T, u }; _ = make<|>; }", "" },
        // Slices, arrays, and tuples
        .{ "fn run(s: []const u8, a: [4]u8, t: struct { u8, bool }) void { _ = .{ s, a, t }; _ = len<|>; }", "a.len s.len t.len" },
        .{ "fn run(s: []const u8) void { _ = s; _ = ptr<|>; }", "s.ptr" },
        // Inside a generic function body, types are inferred from the call-site instance
        .{ "fn generic(comptime T: type, v: T) void { _ = v; _ = depth<|>; }\nfn caller() void { generic(Inner, .{ .depth = 1 }); }", "v.depth" },
        // Functions in a container cannot access the runtime values of the enclosing function
        .{ "fn outer(o: Outer) void { _ = o; const S = struct { fn f() void { _ = depth<|>; } }; _ = S; }", "" },
        // Shadowed local values are not expanded
        .{ "fn run(o: Outer) void { _ = o; { const o: u32 = 1; _ = o; _ = depth<|>; } }", "" },
        // A value capture cannot be modified; a pointer capture can be when the pointer is mutable
        .{ "fn run(xs: []Inner) void { for (xs) |x| { _ = x; _ = bump<|>; } }", "" },
        .{ "fn run(xs: []Inner) void { for (xs) |*x| { _ = x; _ = bump<|>; } }", "x.bump" },
        .{ "fn run(xs: []const Inner) void { for (xs) |*x| { _ = x; _ = bump<|>; } }", "" },
        // An alias of a method is a method too
        .{ "fn run(o: Outer) void { _ = o; _ = peek<|>; }", "o.copy().peek o.inner.peek o.ptr.peek" },
        // Fields of unions
        .{ "const U = union(enum) { in: Inner, n: u8 };\nfn run(u: U) void { _ = u; _ = depth<|>; }", "u.in.depth" },
        // Comptime parameters of an enclosing function are comptime-known
        .{ "fn outer(comptime o: Outer) type { return struct { fn f() void { _ = depth<|>; } }; }", "o.copy().depth o.inner.depth o.ptr.depth" },
        // Methods receiving an optional of the type
        .{ "const W = struct { pub fn peekOpt(self: ?W) u32 { _ = self; return 0; } };\nfn run(w: W) void { _ = w; _ = peekOpt<|>; }", "w.peekOpt" },
    };
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator, "//- /p/main.zig module:app\n{s}{s}\n", .{ types, c[0] });
        defer testing.allocator.free(source);
        const got = try localMemberPaths(source);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("case: {s}\n", .{c[0]});
            return err;
        };
    }
}

test "name completion offers only pub methods of local values whose type is in another file" {
    const got = try localMemberPaths(
        \\//- /p/main.zig module:app
        \\const other = @import("other.zig");
        \\fn run(o: other.Thing) void {
        \\    _ = o;
        \\    _ = val<|>;
        \\}
        \\//- /p/other.zig in:app
        \\pub const Thing = struct {
        \\    value: u32,
        \\    pub fn valid(self: Thing) bool { return self.validate(); }
        \\    fn validate(self: Thing) bool { return self.value != 0; }
        \\};
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("o.valid o.value", got);
}

test "local member paths carry kinds, types, filters and the replaced range" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const Point = struct {
        \\    x: i32,
        \\    inner: struct { @"type": u8 },
        \\    /// Scales the point.
        \\    pub fn scale(self: Point, k: i32) Point { return .{ .x = self.x * k, .inner = self.inner }; }
        \\};
        \\fn run(point: Point) void {
        \\    _ = point;
        \\    _ = pt<|>;
        \\}
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    const items = (try completion.complete(&r, at.file, at.offset, .{ .auto_import = false })).items;
    const find = struct {
        fn find(all: []const completion.Item, label: []const u8) !completion.Item {
            for (all) |it| if (std.mem.eql(u8, it.label, label)) return it;
            std.debug.print("missing `{s}`\n", .{label});
            return error.MissingCompletion;
        }
    }.find;
    const x = try find(items, "point.x");
    try testing.expectEqual(.field, x.kind);
    try testing.expectEqualStrings("i32", x.detail.?);
    // When the name does not start with the input, the whole path is the filter
    try testing.expectEqualStrings("point.x", x.filter.?);
    try testing.expectEqual(@as(u32, at.offset - 2), x.replace.?.start);
    // A name that is a primitive type needs no escaping inside a path
    const t = try find(items, "point.inner.type");
    try testing.expectEqualStrings("u8", t.detail.?);
    const scale = try find(items, "point.scale");
    try testing.expectEqual(.method, scale.kind);
    try testing.expectEqualStrings("Scales the point.", scale.doc.?);
    const desc = try completion.describe(&r, at.file, scale.target.?);
    try testing.expectEqualStrings("pub fn scale(self: Point, k: i32) Point", desc.detail);
}

test "local member paths classify functions as completion after `.` does" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const Thing = @import("Thing.zig");
        \\const Point = struct {
        \\    x: i32,
        \\    pub fn negated(self: Point) Point { return .{ .x = -self.x }; }
        \\};
        \\fn run(thing: Thing, point: Point) void {
        \\    _ = .{ thing, point };
        \\    _ = neg<|>;
        \\}
        \\//- /p/Thing.zig in:app
        \\value: u32,
        \\const Thing = @This();
        \\pub fn negative(self: Thing) bool { return self.value == 0; }
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    const items = (try completion.complete(&r, at.file, at.offset, .{ .auto_import = false })).items;
    // A function whose receiver is its container is Method, in a file with fields as in a struct
    for ([_]struct { []const u8, completion.Item.Kind }{ .{ "point.negated", .method }, .{ "thing.negative", .method } }) |c| {
        const item = for (items) |it| {
            if (std.mem.eql(u8, it.label, c[0])) break it;
        } else return error.MissingCompletion;
        try testing.expectEqual(c[1], item.kind);
    }
}

test "local member paths filter by the member name when it starts with the input" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const Point = struct { scale: u32 };
        \\fn run(point: Point) void {
        \\    _ = point;
        \\    _ = Sca<|>;
        \\}
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    for ((try completion.complete(&r, at.file, at.offset, .{ .auto_import = false })).items) |it| {
        if (std.mem.eql(u8, it.label, "point.scale")) break try testing.expectEqualStrings("scale", it.filter.?);
    } else return error.MissingCompletion;
}

test "local member paths rank below scope names and above namespace members, deeper paths lower" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const std = @import("std");
        \\const Box = struct { mem: u32, inner: struct { mem: u32 } };
        \\fn run(box: Box) void {
        \\    const memory = 2;
        \\    _ = .{ memory, box };
        \\    _ = mem<|>;
        \\}
        \\//- /zig/std/std.zig std
        \\pub const mem = struct { pub fn eql() void {} };
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    const items = (try completion.complete(&r, at.file, at.offset, .{})).items;
    const rankOf = struct {
        fn rankOf(all: []const completion.Item, label: []const u8) ![]const u8 {
            for (all) |it| if (std.mem.eql(u8, it.label, label)) return it.sort.?;
            std.debug.print("missing `{s}`\n", .{label});
            return error.MissingCompletion;
        }
    }.rankOf;
    // Among equal matches, local names rank above member paths of local values, which rank above
    // candidates accessed through a namespace; deeper paths rank lower
    const order = [_][2][]const u8{ .{ "memory", "box.mem" }, .{ "box.mem", "std.mem" }, .{ "box.mem", "box.inner.mem" } };
    for (order) |pair| {
        testing.expect(std.mem.lessThan(u8, try rankOf(items, pair[0]), try rankOf(items, pair[1]))) catch |err| {
            std.debug.print("`{s}` should rank before `{s}`\n", .{ pair[0], pair[1] });
            return err;
        };
    }
}

test "local member paths and auto-import candidates share the candidate limit" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig",
        \\const Stamp = struct { stamp: u32, start: u32 };
        \\fn run(stamp_box: Stamp) void {
        \\    _ = stamp_box;
        \\    _ = st<|>;
        \\}
    );
    const std_file = (try w.add("/lib/std/std.zig", "pub const standard = u32;\npub const static_value = 1;\n")).file;
    try w.setGraph(std_file, &.{}, &.{});
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const scored = struct {
        /// Labels of the candidates besides the names in scope, from the highest score down
        fn scored(rr: *resolve.Resolver, file: FileId, offset: u32, limit: usize, incomplete: *bool) ![]const []const u8 {
            const result = try completion.complete(rr, file, offset, .{ .max_auto_imports = limit });
            incomplete.* = result.is_incomplete;
            const items = try rr.arena.dupe(completion.Item, result.items);
            std.mem.sort(completion.Item, items, {}, struct {
                fn less(_: void, a: completion.Item, b: completion.Item) bool {
                    return std.mem.lessThan(u8, a.sort.?, b.sort.?);
                }
            }.less);
            var labels: std.ArrayList([]const u8) = .empty;
            for (items) |it| if (it.weight == 0) try labels.append(rr.arena, it.label);
            return labels.items;
        }
    }.scored;
    var incomplete = false;
    const all = try scored(&r, added.file, added.cursor, std.math.maxInt(usize), &incomplete);
    try testing.expect(!incomplete);
    var members: usize = 0;
    for (all) |label| {
        if (std.mem.startsWith(u8, label, "stamp_box.")) members += 1;
    }
    try testing.expect(members > 0 and members < all.len);
    // Over the limit, the highest-scoring candidates are kept, without a separate limit per source
    for (1..all.len + 1) |limit| {
        const kept = try scored(&r, added.file, added.cursor, limit, &incomplete);
        try testing.expectEqual(limit < all.len, incomplete);
        try testing.expectEqual(limit, kept.len);
        for (kept, all[0..limit]) |a, b| try testing.expectEqualStrings(b, a);
    }
}

test "local member paths are incomplete only when a path left out can be built" {
    // `abd` needs a mutable receiver and `abmake` is not a method: neither is an item, so a limit
    // that keeps every other path leaves nothing out
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig",
        \\const Big = struct {
        \\    ab1: u8,
        \\    ab2: u8,
        \\    pub fn abc(self: Big) void { _ = self; }
        \\    pub fn abd(self: *Big) void { _ = self; }
        \\    pub fn abmake() Big { return undefined; }
        \\};
        \\fn run(b: Big) void {
        \\    _ = b;
        \\    _ = ab<|>;
        \\}
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_]struct { usize, bool }{ .{ 2, true }, .{ 3, false }, .{ 4, false } }) |c| {
        const result = try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false, .max_auto_imports = c[0] });
        var paths: usize = 0;
        for (result.items) |it| {
            if (it.weight == 0) paths += 1;
        }
        try testing.expectEqual(@min(c[0], 3), paths);
        try testing.expectEqual(c[1], result.is_incomplete);
    }
}

/// Labels of the candidates that match the input in name completion, in rank order, joined by
/// spaces
fn rankedLabels(source: []const u8, auto_import: bool) ![]u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(source);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    var labels: std.ArrayList([]const u8) = .empty;
    for ((try completion.complete(&r, at.file, at.offset, .{ .auto_import = auto_import })).items) |it| {
        if (it.score > 0) try labels.append(w.arena.allocator(), it.label);
    }
    return testing.allocator.dupe(u8, try std.mem.join(w.arena.allocator(), " ", labels.items));
}

/// Checks `cases` in order: the completion ranking at the cursor in the source of each case,
/// placed after `decls`
fn expectRanked(decls: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator, "//- /p/main.zig module:app\n{s}{s}\n", .{ decls, c[0] });
        defer testing.allocator.free(source);
        const got = try rankedLabels(source, false);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("case: {s}\n", .{c[0]});
            return err;
        };
    }
}

/// Three container members matching `cd` equally: without the expected-type boost, they rank in
/// declaration order
const expected_decls =
    \\const Want = enum { a, b };
    \\const Other = struct {
    \\    w: Want = .a,
    \\    pub fn put(self: Other, w: Want) void { _ = .{ self, w }; }
    \\};
    \\const Hook = struct { call: *const fn (Want) void };
    \\const Tagged = union(Want) { a: u8, b: void };
    \\const cd_n: u8 = 0;
    \\const cd_o: Other = .{};
    \\const cd_w: Want = .a;
    \\fn take(w: Want) void { _ = w; }
    \\fn takeOther(o: Other) void { _ = o; }
    \\
;
const unchanged = "cd_n cd_o cd_w";
const want_first = "cd_w cd_n cd_o";
const other_first = "cd_o cd_n cd_w";

test "name completion ranks candidates fitting the expected type first" {
    try expectRanked(expected_decls, &.{
        .{ "fn run() void { _ = cd<|>; }", unchanged },
        // Call arguments: calling a method through a value skips self; calling through the type
        // or calling a field of function type does not
        .{ "fn run() void { take(cd<|>); }", want_first },
        .{ "fn run() void { cd_o.put(cd<|>); }", want_first },
        .{ "fn run() void { Other.put(cd<|>, .a); }", other_first },
        .{ "fn run() void { Other.put(cd_o, cd<|>); }", want_first },
        .{ "fn run(h: Hook) void { h.call(cd<|>); }", want_first },
        // Declarations with a type annotation, including declarations in containers and default
        // values of fields; the same while typing, before the `;` exists
        .{ "fn run() void { const x: Want = cd<|>; _ = x; }", want_first },
        .{ "fn run() void { var x: Want = cd<|>; _ = &x; }", want_first },
        .{ "fn run() void {\n    const x: Want = cd<|>\n}", want_first },
        .{ "const top: Want = cd<|>;", want_first },
        .{ "const Holder = struct { w: Want = cd<|> };", want_first },
        // Return values
        .{ "fn run() Want { return cd<|>; }", want_first },
        .{ "fn run() !Want { return cd<|>; }", want_first },
        .{ "fn run() Other { return cd<|>; }", other_first },
        // Fields in initializers: the field of the initializer's type (annotated, written out, or
        // from the parameter it is passed to); no expected type when there is no such field
        .{ "fn run() void { const o: Other = .{ .w = cd<|> }; _ = o; }", want_first },
        .{ "fn run() void { _ = Other{ .w = cd<|> }; }", want_first },
        .{ "fn run() void { takeOther(.{ .w = cd<|> }); }", want_first },
        .{ "fn run() void { takeOther(.{ .missing = cd<|> }); }", unchanged },
        // Assignments and comparisons; a tagged union compared with its tag
        .{ "fn run() void { var x: Want = .a; x = cd<|>; }", want_first },
        .{ "fn run(w: Want) void { if (w == cd<|>) {} }", want_first },
        .{ "fn run(o: Other) void { if (o.w != cd<|>) {} }", want_first },
        .{ "fn run(t: Tagged) void { if (t == cd<|>) {} }", want_first },
        // `@as(T, e)`; the branches of `if`, `switch`, `orelse`, and `catch`, `break :label`, and
        // `comptime e` take the expected type of the expression they produce
        .{ "fn run() void { _ = @as(Want, cd<|>); }", want_first },
        .{ "fn run(c: bool) void { const x: Want = if (c) .a else cd<|>; _ = x; }", want_first },
        .{ "fn run(n: u8) void { const x: Want = switch (n) { 0 => .a, else => cd<|> }; _ = x; }", want_first },
        .{ "fn run(o: ?Want) void { const x: Want = o orelse cd<|>; _ = x; }", want_first },
        .{ "fn run(e: anyerror!Want) void { const x: Want = e catch cd<|>; _ = x; }", want_first },
        .{ "fn run() void { const x: Want = blk: { break :blk cd<|>; }; _ = x; }", want_first },
        .{ "fn run() void { const x: Want = comptime cd<|>; _ = x; }", want_first },
        .{ "fn run(c: bool) void { const x: Other = if (c) .{} else cd<|>; _ = x; }", other_first },
    });
}

test "candidates fit the expected type only by exact rules" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "Want", "const cd_b: Want = .a;", true },
        .{ "?Want", "const cd_b: Want = .a;", true },
        .{ "anyerror!Want", "const cd_b: Want = .a;", true },
        .{ "?*const Want", "const cd_b: *Want = undefined;", true },
        .{ "*const Want", "const cd_b: *Want = undefined;", true },
        .{ "[]const u8", "const cd_b: []u8 = undefined;", true },
        .{ "type", "const cd_b = u8;", true },
        // A string constant (a pointer to an array) as a slice or a many-item pointer
        .{ "[]const u8", "const cd_b = \"hello\";", true },
        .{ "[:0]const u8", "const cd_b = \"hello\";", true },
        .{ "[*]const u8", "const cd_b = \"hello\";", true },
        // Error sets and error unions whose error set fits
        .{ "anyerror!Want", "const cd_b: anyerror = error.X;", true },
        .{ "error{ X, Y }!Want", "const cd_b: error{X}!Want = .a;", true },
        .{ "anyerror!Want", "const cd_b: error{X}!Want = .a;", true },
        // A function as a pointer to it
        .{ "*const fn () Want", "fn cd_b() Want { return .a; }", true },
        // Functions whose return value fits; a function pointer is not its return value, and it
        // does not complete as a call
        .{ "Want", "fn cd_b() Want { return .a; }", true },
        .{ "Want", "const cd_b: *const fn () Want = undefined;", false },
        // Other conversions, such as integer widening and comptime_int, do not count
        .{ "u64", "const cd_b: u32 = 0;", false },
        .{ "u32", "const cd_b = 1;", false },
        .{ "*Want", "const cd_b: *const Want = undefined;", false },
        .{ "[]u8", "const cd_b: []const u8 = undefined;", false },
        .{ "Want", "const cd_b: ?Want = .a;", false },
        .{ "Want", "fn cd_b() ?Want { return .a; }", false },
        .{ "[]u8", "const cd_b = \"hello\";", false },
        .{ "[:1]const u8", "const cd_b = \"hello\";", false },
        .{ "error{X}!Want", "const cd_b: error{ X, Y } = error.X;", false },
        .{ "error{X}!Want", "const cd_b: error{X}!Other = .{};", false },
    };
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\//- /p/main.zig module:app
            \\const Want = enum {{ a, b }};
            \\const Other = struct {{}};
            \\const cd_a: Other = .{{}};
            \\{s}
            \\fn run() void {{
            \\    const x: {s} = cd<|>;
            \\    _ = x;
            \\}}
            \\
        , .{ c[1], c[0] });
        defer testing.allocator.free(source);
        const got = try rankedLabels(source, false);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(if (c[2]) "cd_b cd_a" else "cd_a cd_b", got) catch |err| {
            std.debug.print("expected `{s}`, candidate `{s}`\n", .{ c[0], c[1] });
            return err;
        };
    }
}

test "pointers fit the expected type by the compiler's attribute rules" {
    // Prevents ranking `*volatile` / `*align(1)` candidates first where `*const u32` is expected,
    // and Zig-callconv function pointers where a `callconv(.c)` one is. Expected values: zig 0.17.0
    // accepts the coercions marked true and rejects the others (`expected type '*const u32',
    // found '*volatile u32'`, and so on).
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "*const u32", "const cd_b: *align(8) u32 = undefined;", true },
        .{ "*align(1) const u32", "const cd_b: *u32 = undefined;", true },
        .{ "*volatile const u32", "const cd_b: *u32 = undefined;", true },
        .{ "*allowzero const u32", "const cd_b: *u32 = undefined;", true },
        .{ "[]const u32", "const cd_b: []align(8) u32 = undefined;", true },
        .{ "*const fn () callconv(.c) void", "fn cd_b() callconv(.c) void {}", true },
        .{ "*const u32", "const cd_b: *volatile u32 = undefined;", false },
        .{ "*const u32", "const cd_b: *align(1) u32 = undefined;", false },
        .{ "*const u32", "const cd_b: *allowzero u32 = undefined;", false },
        .{ "[]const u32", "const cd_b: []align(1) u32 = undefined;", false },
        .{ "*const fn () callconv(.c) void", "fn cd_b() void {}", false },
        .{ "*const fn () callconv(.c) void", "const cd_b: *const fn () void = undefined;", false },
    };
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\//- /p/main.zig module:app
            \\const Other = struct {{}};
            \\const cd_a: Other = .{{}};
            \\{s}
            \\fn run() void {{
            \\    const x: {s} = cd<|>;
            \\    _ = x;
            \\}}
            \\
        , .{ c[1], c[0] });
        defer testing.allocator.free(source);
        const got = try rankedLabels(source, false);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(if (c[2]) "cd_b cd_a" else "cd_a cd_b", got) catch |err| {
            std.debug.print("expected `{s}`, candidate `{s}`\n", .{ c[0], c[1] });
            return err;
        };
    }
}

test "function pointer values rank by the expected type only as what they are" {
    // Parameters and locals of type `*const fn () Tone` are inserted without a call, so the
    // expected type `Tone` does not rank them first; it moves only `tint` up
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "    _ = tin<|>;", "tint_note tint_cb tint tint_note.len tint_note.ptr" },
        .{ "    apply(tin<|>);", "tint tint_note tint_cb tint_note.len tint_note.ptr" },
        .{ "    const cb_fn: *const fn () Tone = tint_cb;\n    const cb_n: u8 = 0;\n    _ = cb_n;\n    apply(cb_<|>);", "cb_n cb_fn" },
    };
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\//- /p/main.zig module:app
            \\const Tone = enum {{ warm, cool }};
            \\fn apply(t: Tone) void {{ _ = t; }}
            \\fn work(tint: Tone, tint_cb: *const fn () Tone, tint_note: []const u8) void {{
            \\    _ = .{{ tint, tint_cb, tint_note }};
            \\{s}
            \\}}
            \\comptime {{ _ = &work; }}
            \\
        , .{c[0]});
        defer testing.allocator.free(source);
        const got = try rankedLabels(source, false);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("case: {s}\n", .{c[0]});
            return err;
        };
    }
}

test "comparisons expect what the other side can be compared with" {
    // An error union compares only with an error set, and slices do not compare at all, so the
    // payload type and slices rank as without an expected type
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "    _ = fail<|>;", "fail_total fail_kind" },
        .{ "    _ = outcome == fail<|>;", "fail_kind fail_total" },
        .{ "    _ = fail_total == fail<|>;", "fail_total fail_kind" },
        .{ "    _ = txt<|>;", "txt_n txt_other txt_other.len txt_other.ptr text text.len text.ptr" },
        .{ "    _ = text == txt<|>;", "txt_n txt_other txt_other.len txt_other.ptr text text.len text.ptr" },
    };
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\//- /p/main.zig module:app
            \\fn probe(outcome: anyerror!u32, fail_kind: anyerror, fail_total: u32, text: []const u8, txt_other: []const u8, txt_n: u8) void {{
            \\    _ = .{{ outcome, fail_kind, fail_total, text, txt_other, txt_n }};
            \\{s}
            \\}}
            \\comptime {{ _ = &probe; }}
            \\
        , .{c[0]});
        defer testing.allocator.free(source);
        const got = try rankedLabels(source, false);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("case: {s}\n", .{c[0]});
            return err;
        };
    }
}

test "string constants and calls returning error unions fit by coercion" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "fn greet() void { const motto_len: u32 = 1; _ = &motto_len; _ = mott<|>; }", "motto_len motto" },
        .{ "fn greet() void { const motto_len: u32 = 1; _ = &motto_len; show(mott<|>); }", "motto motto_len" },
        .{ "fn load(s: []const u8) !Tone { _ = &s; _ = read<|>; return .warm; }", "readCount readTone" },
        .{ "fn load(s: []const u8) !Tone { _ = &s; return read<|>; }", "readTone readCount" },
    };
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\//- /p/main.zig module:app
            \\const Tone = enum {{ warm, cool }};
            \\const motto = "hello";
            \\fn show(text: []const u8) void {{ _ = text; }}
            \\fn readCount(s: []const u8) u32 {{ return @intCast(s.len); }}
            \\fn readTone(s: []const u8) !Tone {{ if (s.len == 0) return error.Empty; return .warm; }}
            \\{s}
            \\
        , .{c[0]});
        defer testing.allocator.free(source);
        const got = try rankedLabels(source, false);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("case: {s}\n", .{c[0]});
            return err;
        };
    }
}

test "expected types are not used where the syntax tree may be wrong" {
    try expectRanked(expected_decls ++ "const cd_t = u8;\n", &.{
        // An unclosed call takes the next line as its arguments `x` and `cd`; the type of `x`,
        // `Want`, is not the expected type
        .{ "fn run() void {\n    var x: Want = .a;\n    take(cd_n,\n    x = cd<|>;\n    _ = &x;\n}", "cd_n cd_o cd_w cd_t" },
        // The call at the cursor is not closed; the statement has a syntax error
        .{ "fn run() void {\n    take(cd<|>\n}", "cd_n cd_o cd_w cd_t" },
        .{ "fn run() void {\n    const o: Other = .{ .w = cd<|>, .w = };\n    _ = o;\n}", "cd_n cd_o cd_w cd_t" },
        // Syntax errors in other statements do not matter, including a `;` missing from the
        // previous statement
        .{ "fn run() void {\n    const y: u8 = ;\n    const x: Want = cd<|>;\n    _ = .{ x, y };\n}", "cd_w cd_n cd_o cd_t" },
        .{ "fn run() void {\n    const y: u8 = 0\n    const x: Want = cd<|>;\n    _ = .{ x, y };\n}", "cd_w cd_n cd_o cd_t" },
        // An unclosed call ends before a declaration on the next line
        .{ "fn run() void {\n    take(cd_n,\n    const x: Want = cd<|>;\n    _ = x;\n}", "cd_w cd_n cd_o cd_t" },
    });
}

test "expected types of generic parameters are not used" {
    try expectRanked(expected_decls ++
        \\fn generic(comptime T: type, v: T) void { _ = v; }
        \\fn any(v: anytype) void { _ = v; }
        \\
    , &.{
        // Parameters that depend on comptime parameters, and anytype parameters
        .{ "fn run() void { generic(Want, cd<|>); }", unchanged },
        .{ "fn run() void { any(cd<|>); }", unchanged },
        // Inside a generic function body, types are inferred from the call-site instance; without
        // a call site the type is unknown
        .{ "fn inner(comptime T: type) void { const x: T = cd<|>; _ = x; }\nfn caller() void { inner(Want); }", want_first },
        .{ "fn inner(comptime T: type) void { const x: T = cd<|>; _ = x; }", unchanged },
    });
}

test "local member paths and auto-import candidates fitting the expected type rank first" {
    const source =
        \\//- /p/main.zig module:app
        \\const std = @import("std");
        \\const Pair = struct {{ a: u8, z: std.Want }};
        \\fn run(cd_p: Pair) void {{
        \\    _ = cd_p;
        \\    {s}
        \\}}
        \\//- /zig/std/std.zig std
        \\pub const Want = enum {{ a, b }};
        \\pub const cd_a: u8 = 0;
        \\pub const cd_z: Want = .a;
        \\
    ;
    const cases = [_]struct { []const u8, bool }{ .{ "_ = cd<|>;", false }, .{ "const x: std.Want = cd<|>;\n    _ = x;", true } };
    for (cases) |c| {
        const text = try std.fmt.allocPrint(testing.allocator, source, .{c[0]});
        defer testing.allocator.free(text);
        const got = try rankedLabels(text, true);
        defer testing.allocator.free(got);
        var it = std.mem.tokenizeScalar(u8, got, ' ');
        var rank: std.StringHashMapUnmanaged(usize) = .empty;
        defer rank.deinit(testing.allocator);
        var i: usize = 0;
        while (it.next()) |label| : (i += 1) try rank.put(testing.allocator, label, i);
        for ([_][2][]const u8{ .{ "cd_p.a", "cd_p.z" }, .{ "std.cd_a", "std.cd_z" } }) |pair| {
            const a = rank.get(pair[0]) orelse return error.MissingCompletion;
            const z = rank.get(pair[1]) orelse return error.MissingCompletion;
            testing.expectEqual(c[1], z < a) catch |err| {
                std.debug.print("case: {s}\nranked: {s}\n", .{ c[0], got });
                return err;
            };
        }
    }
}

test "completion item kinds follow what each symbol is" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const std = @import("std");
        \\const Point = struct {
        \\    x: i32,
        \\    pub fn len(self: Point) u32 { _ = self; return 0; }
        \\    pub fn origin() Point { return .{ .x = 0 }; }
        \\};
        \\const Color = enum { red, green };
        \\const Shape = union { circle: u32 };
        \\const Index = u32;
        \\const limit = 10;
        \\var counter: u32 = 0;
        \\const run_alias = run;
        \\fn run(comptime T: type, p: Point) void {
        \\    const local = 1;
        \\    var mutable: u32 = 0;
        \\    const Local = struct {};
        \\    _ = .{ T, local, &mutable, Local, p.x, p.len(), Point.origin };
        \\    _ = zz<|>;
        \\}
        \\//- /zig/std/std.zig std
        \\pub const mem = struct {};
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    const text = try w.arena.allocator().dupe(u8, (try ctx.get(database.syntax.SourceText, at.file)).text);
    const items = (try completion.complete(&r, at.file, at.offset, .{ .auto_import = false })).items;
    const cases = [_]struct { []const u8, completion.Item.Kind }{
        .{ "std", .namespace },
        .{ "Point", .@"struct" },
        .{ "Color", .@"enum" },
        .{ "Shape", .type },
        .{ "Index", .type },
        .{ "limit", .constant },
        .{ "counter", .variable },
        .{ "run", .function },
        .{ "run_alias", .function },
        .{ "T", .type_param },
        .{ "p", .param },
        .{ "local", .constant },
        .{ "mutable", .variable },
        .{ "Local", .@"struct" },
    };
    for (cases) |c| {
        const item = for (items) |it| {
            if (std.mem.eql(u8, it.label, c[0])) break it;
        } else return error.MissingCompletion;
        testing.expectEqual(c[1], item.kind) catch |err| {
            std.debug.print("kind of `{s}`\n", .{c[0]});
            return err;
        };
    }
    // Members: fields, methods (the first parameter is the enclosing container) and plain functions
    const member_at: u32 = @intCast(std.mem.indexOf(u8, text, "p.x").? + 2);
    const members = (try completion.complete(&r, at.file, member_at, .{ .auto_import = false })).items;
    for ([_]struct { []const u8, completion.Item.Kind }{ .{ "x", .field }, .{ "len", .method } }) |c| {
        const item = for (members) |it| {
            if (std.mem.eql(u8, it.label, c[0])) break it;
        } else return error.MissingCompletion;
        try testing.expectEqual(c[1], item.kind);
    }
    const type_at: u32 = @intCast(std.mem.indexOf(u8, text, "Point.origin").? + 6);
    for ((try completion.complete(&r, at.file, type_at, .{ .auto_import = false })).items) |it| {
        if (std.mem.eql(u8, it.label, "origin")) break try testing.expectEqual(.function, it.kind);
    } else return error.MissingCompletion;
}

test "completion item kinds in generic bodies follow a call site and fall back when the type is unknown" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const Point = struct { x: i32 };
        \\const broken = missing_name;
        \\fn make(comptime T: type) void {
        \\    const Alias = T;
        \\    _ = Alias;
        \\    _ = zz<|>;
        \\}
        \\fn caller() void {
        \\    make(Point);
        \\}
    );
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = f.cursor.?;
    const items = (try completion.complete(&r, at.file, at.offset, .{ .auto_import = false })).items;
    // `Alias` is inferred as a struct from the instance at the call site `make(Point)`; the type
    // of `broken` cannot be inferred, so it is a constant by its declaration
    for ([_]struct { []const u8, completion.Item.Kind }{ .{ "Alias", .@"struct" }, .{ "T", .type_param }, .{ "broken", .constant } }) |c| {
        const item = for (items) |it| {
            if (std.mem.eql(u8, it.label, c[0])) break it;
        } else return error.MissingCompletion;
        testing.expectEqual(c[1], item.kind) catch |err| {
            std.debug.print("kind of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "selected function completions resolve to the signature as written in the source" {
    const text =
        \\const Point = struct {
        \\    x: i32,
        \\    pub fn init(x: i32, y: i32) Point { return .{ .x = x + y }; }
        \\    /// Distance to the origin
        \\    pub fn dist(self: Point, scale: u32) u32 { _ = .{ self, scale }; return 0; }
        \\    pub const length = dist;
        \\};
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        items: []T,
        \\        pub fn append(self: *Self, item: T) !void { _ = .{ self, item }; }
        \\    };
        \\}
        \\fn add(
        \\    /// the first
        \\    a: u32,
        \\    b: u32, // the second
        \\) callconv(.c) u32 { return a + b; }
        \\fn run(p: Point, list: *List(u8)) void {
        \\    const q: Point = .init(1, 2);
        \\    _ = .{ p.dist(1), list.append(1), q, add(1, 2) };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = struct {
        fn of(needle: []const u8, delta: u32) u32 {
            return @as(u32, @intCast(std.mem.indexOf(u8, text, needle).?)) + delta;
        }
    }.of;
    const cases = [_]struct { u32, []const u8, ?[]const u8 }{
        // Methods, and aliases pointing to them (giving the signature of the function they point
        // to); fields have none
        .{ at("p.dist", 2), "dist", "pub fn dist(self: Point, scale: u32) u32" },
        .{ at("p.dist", 2), "length", "pub fn dist(self: Point, scale: u32) u32" },
        .{ at("p.dist", 2), "x", null },
        // Methods of generic instances: as written in the source, without substituting inferred
        // types
        .{ at("list.append", 5), "append", "pub fn append(self: *Self, item: T) !void" },
        // decl literal
        .{ at(".init(1", 1), "init", "pub fn init(x: i32, y: i32) Point" },
        // Names in scope; multi-line parameter lists drop comments and the trailing comma;
        // constants have none
        .{ at("add(1, 2)", 3), "add", "fn add(a: u32, b: u32) callconv(.c) u32" },
        .{ at("add(1, 2)", 3), "List", "fn List(comptime T: type) type" },
        .{ at("add(1, 2)", 3), "Point", null },
    };
    for (cases) |c| {
        const items = (try completion.complete(&r, file, c[0], .{ .auto_import = false })).items;
        const item = for (items) |it| {
            if (std.mem.eql(u8, it.label, c[1])) break it;
        } else return error.MissingCompletion;
        const expected = c[2] orelse {
            try testing.expect(item.target == null);
            continue;
        };
        const description = try completion.describe(&r, file, item.target orelse return error.NoTarget);
        testing.expectEqualStrings(expected, description.detail) catch |err| {
            std.debug.print("completion `{s}`\n", .{c[1]});
            return err;
        };
        // The list does not include signatures
        try testing.expect(item.detail == null);
        if (std.mem.eql(u8, c[1], "dist")) try testing.expect(std.mem.startsWith(u8, description.doc, "Distance to the origin\n\n"));
    }
}

test "goto declaration of reified fields named by comptime parsed strings" {
    // Field names parsed out of help text (as zig-clap does): goes to the parameter name in the
    // help text
    const text =
        \\const Param = struct { long: ?[]const u8 = null };
        \\fn count(str: []const u8) usize {
        \\    var n: usize = 1;
        \\    for (str) |ch| n += @intFromBool(ch == '\n');
        \\    return n;
        \\}
        \\fn parse(comptime str: []const u8) [count(str)]Param {
        \\    var out: [count(str)]Param = undefined;
        \\    var n: usize = 0;
        \\    var start: usize = 0;
        \\    var i: usize = 0;
        \\    while (i <= str.len) : (i += 1) {
        \\        if (i < str.len and str[i] != '\n') continue;
        \\        var name_end = start + 2;
        \\        while (name_end < i and str[name_end] != ' ') name_end += 1;
        \\        out[n] = .{ .long = str[start + 2 .. name_end] };
        \\        n += 1;
        \\        start = i + 1;
        \\    }
        \\    return out;
        \\}
        \\fn Args(comptime params: []const Param) type {
        \\    var names: [params.len][]const u8 = undefined;
        \\    var types: [params.len]type = undefined;
        \\    for (params, 0..) |p, k| {
        \\        names[k] = p.long.?[0..p.long.?.len] ++ "";
        \\        types[k] = bool;
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &@splat(.{}));
        \\}
        \\const help = "--count Number of items";
        \\const params = parse(
        \\    \\--alpha First option
        \\    \\--beta Second option
        \\);
        \\const other = parse(help);
        \\fn run(a: Args(&params), b: Args(&other)) void {
        \\    const local = comptime parse(
        \\        \\--gamma Local option
        \\    );
        \\    const c: Args(&local) = undefined;
        \\    _ = .{ a.beta, b.count, c.gamma };
        \\}
        \\
    ;
    // The type of the field attributes of `@Struct` comes from std.builtin
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root_path = try std.fs.path.join(w.arena.allocator(), &.{ env.std_dir, "std.zig" });
    const std_root = try w.vfs.intern(std_root_path);
    const file = (try w.add("/p/main.zig", text)).file;
    try w.setGraph(std_root, &.{}, &.{});
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        // Second line of a multi-line string
        .{ "beta, b.", "beta Second" },
        // A plain string through another constant
        .{ "count, c.", "count Number" },
        // Local constant
        .{ "gamma };", "gamma Local" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        const name_len = std.mem.indexOfAny(u8, c[0], ",; ").?;
        testing.expectEqualStrings(c[0][0..name_len], text[t.start..t.end]) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..t.end] });
            return err;
        };
        try testing.expect(std.mem.startsWith(u8, text[t.start..], c[1]));
    }
}

test "goto declaration of enum literals passed to anytype parameters that the callee converts" {
    // Literals in `testing.expectEqual(.x, actual)` are converted by the callee through
    // `@TypeOf(expected, actual)`: they used to have no goto target
    const text =
        \\const Color = enum { red, green };
        \\const names = [_][:0]const u8{ "fast", "slow" };
        \\const Mode = @Enum(u8, .exhaustive, &names, &[_]u8{ 0, 1 });
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
        \\    const m: Mode = .slow;
        \\    try expectEqual(.slow, m);
        \\    try expectEqual(.red, @as(?Color, c));
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "green, c", "green }" },
        // Reified enum: the string literal of the name
        .{ "slow, m", "slow\" }" },
        // The peer type is optional
        .{ "red, @as", "red, green" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.definition(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[1])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..t.end] });
            return err;
        };
    }
}

test "goto declaration of enum and struct literals in the arguments of type-constructing builtins" {
    // The arguments got no result type, so their literals had no target
    const text =
        \\const I = @Int(.unsigned, 8);
        \\const P = @Pointer(.one, .{ .@"const" = true }, u8, null);
        \\const S = @Struct(.auto, null, &.{"a"}, &.{u8}, &.{.{ .@"comptime" = false }});
        \\const U = @Union(.@"extern", null, &.{"x"}, &.{u32}, &.{.{}});
        \\const E = @Enum(u8, .exhaustive, &.{"a"}, &.{0});
        \\const F = @Fn(&.{u8}, &.{.{ .@"noalias" = false }}, void, .{ .@"callconv" = .auto });
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    // Cursor text, then the target: its name and the declaration it is a member of
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "unsigned, 8", "unsigned", "Signedness" },
        .{ "one, .{", "one", "Size" },
        .{ "const\" = true", "@\"const\"", "Attributes" },
        .{ "auto, null", "auto", "ContainerLayout" },
        .{ "comptime\" = false", "@\"comptime\"", "FieldAttributes" },
        .{ "extern\", null", "@\"extern\"", "ContainerLayout" },
        .{ "exhaustive, &", "exhaustive", "Mode" },
        .{ "noalias\" = false", "@\"noalias\"", "ParamAttributes" },
        .{ "callconv\" = .auto", "@\"callconv\"", "Attributes" },
        .{ "auto });", "auto", "CallingConvention" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        try testing.expect(std.mem.endsWith(u8, w.vfs.path(t.file), "lang.zig"));
        const target_text = (try ctx.get(database.syntax.SourceText, t.file)).text;
        testing.expectEqualStrings(c[1], target_text[t.start..t.end]) catch |err| {
            std.debug.print("case {d}\n", .{i});
            return err;
        };
        // The container: declared on the target's line (`pub const Mode = enum { a, b };`), or
        // the nearest line above that is indented less than the target
        var line_start = std.mem.lastIndexOfScalar(u8, target_text[0..t.start], '\n').? + 1;
        const indent = t.start - line_start;
        const same_line = std.mem.trimStart(u8, target_text[line_start..t.start], " ");
        const header = if (std.mem.startsWith(u8, same_line, "pub const ")) same_line else while (line_start > 0) {
            const prev = if (std.mem.lastIndexOfScalar(u8, target_text[0 .. line_start - 1], '\n')) |n| n + 1 else 0;
            const line = target_text[prev .. line_start - 1];
            line_start = prev;
            const trimmed = std.mem.trimStart(u8, line, " ");
            if (trimmed.len != 0 and line.len - trimmed.len < indent) break trimmed;
        } else unreachable;
        testing.expect(std.mem.startsWith(u8, header, "pub const ") and std.mem.startsWith(u8, header["pub const ".len..], c[2]) and header["pub const ".len + c[2].len] == ' ') catch |err| {
            std.debug.print("case {d}: container `{s}`\n", .{ i, header });
            std.debug.print("case {d}\n", .{i});
            return err;
        };
    }
}

test "goto declaration of switch prong literals on a member of a loop's type" {
    // In merged inference the type of the literal at the cursor is `@Type(.enum_literal)`: it used
    // to be treated as an already known type instead of being inferred per iteration, and had no
    // goto target
    const text =
        \\const Kind = enum { input, derived };
        \\const A = struct {
        \\    pub const kind: Kind = .input;
        \\};
        \\const B = struct {
        \\    pub const kind: Kind = .derived;
        \\};
        \\fn count() u32 {
        \\    var n: u32 = 0;
        \\    inline for (.{ A, B }) |Q| {
        \\        switch (Q.kind) {
        \\            .input => n += 1,
        \\            .derived => n += 2,
        \\        }
        \\    }
        \\    return n;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "input =>", "input, derived" },
        .{ "derived =>", "derived }" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.definition(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[1])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..t.end] });
            return err;
        };
    }
}

test "goto declaration of enum literals in branches whose result is the peer type" {
    // `if` / `switch` without a result type: the branches are converted by peer type, and
    // `.invalid` is a member of Kind; it used to have no goto target
    const text =
        \\const Kind = enum { invalid, name, none };
        \\const Tok = struct { kind: Kind };
        \\fn f(t: ?Tok, n: u8) bool {
        \\    const a = if (t) |x| x.kind else .invalid;
        \\    const b = switch (n) {
        \\        0 => a,
        \\        else => .none,
        \\    };
        \\    return a == b;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "invalid;", "invalid, name" },
        .{ "none,\n", "none }" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.definition(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[1])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..t.end] });
            return err;
        };
    }
}

test "completion through a switch whose other prong is an empty tuple literal" {
    // Peer type resolution of `else => &.{}` with a slice gives a slice: it used to fail, leaving
    // completion empty
    const labels = try completionLabels(
        \\const Item = struct { label: []const u8, kind: u8 };
        \\fn f(list: []const Item, n: u8) usize {
        \\    const items = switch (n) {
        \\        0 => list,
        \\        else => &.{},
        \\    };
        \\    for (items) |it| _ = it.<|>;
        \\    return items.len;
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("label kind", labels);
}

test "goto declaration of a reified field whose name is not traceable to a literal goes to the construction" {
    // The name consists of a single byte (zig-clap's short parameter names): it cannot be traced to
    // characters in a literal, and used to have no goto target
    const text =
        \\const Names = struct {
        \\    short: ?u8 = null,
        \\    fn name(names: *const Names) []const u8 {
        \\        if (names.short) |*short| return @as(*const [1]u8, short);
        \\        return "";
        \\    }
        \\};
        \\fn Args(comptime params: []const Names) type {
        \\    var names: [params.len][]const u8 = undefined;
        \\    var types: [params.len]type = undefined;
        \\    for (params, 0..) |p, k| {
        \\        const n = p.name();
        \\        names[k] = n[0..n.len] ++ "";
        \\        types[k] = bool;
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &@splat(.{}));
        \\}
        \\const params = [_]Names{.{ .short = 'h' }};
        \\fn run(a: Args(&params)) bool {
        \\    return a.h;
        \\}
        \\
    ;
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root = try w.vfs.intern(try std.fs.path.join(w.arena.allocator(), &.{ env.std_dir, "std.zig" }));
    const file = (try w.add("/p/main.zig", text)).file;
    try w.setGraph(std_root, &.{}, &.{});
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const target = try definition.definition(&r, file, @intCast(std.mem.indexOf(u8, text, "a.h").? + 2)) orelse return error.NoDefinition;
    try testing.expectEqual(std.mem.indexOf(u8, text, "@Struct(").?, target.start);
}

test "goto declaration of a reified field named by a byte copied from a string literal" {
    // The short parameter name is copied from one byte of the help text (zig-clap's `-h`): it used
    // to be untraceable to the literal, so goto went to the construction call
    const text =
        \\const Names = struct {
        \\    short: ?u8 = null,
        \\    fn name(names: *const Names) []const u8 {
        \\        if (names.short) |*short| return @as(*const [1]u8, short);
        \\        return "";
        \\    }
        \\};
        \\fn parse(comptime str: []const u8) [1]Names {
        \\    var out: [1]Names = .{.{}};
        \\    for (str, 0..) |c, i| {
        \\        if (i > 0 and str[i - 1] == '-') out[0].short = c;
        \\    }
        \\    return out;
        \\}
        \\fn Args(comptime params: []const Names) type {
        \\    var names: [params.len][]const u8 = undefined;
        \\    var types: [params.len]type = undefined;
        \\    for (params, 0..) |p, k| {
        \\        const n = p.name();
        \\        names[k] = n[0..n.len] ++ "";
        \\        types[k] = bool;
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &@splat(.{}));
        \\}
        \\const params = parse("  -h  Display help");
        \\fn run(a: Args(&params)) bool {
        \\    return a.h;
        \\}
        \\
    ;
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root = try w.vfs.intern(try std.fs.path.join(w.arena.allocator(), &.{ env.std_dir, "std.zig" }));
    const file = (try w.add("/p/main.zig", text)).file;
    try w.setGraph(std_root, &.{}, &.{});
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const target = try definition.definition(&r, file, @intCast(std.mem.indexOf(u8, text, "a.h").? + 2)) orelse return error.NoDefinition;
    const h = std.mem.indexOf(u8, text, "-h  Display").? + 1;
    try testing.expectEqual(h, target.start);
    try testing.expectEqual(h + 1, target.end);
}

test "goto declaration of a reified field whose name comes from an argument in another file" {
    // The help text is in a third file and passed through two levels of generic functions
    // (zig-clap's `clap.parse(..., &args.params, ...)`): literals used to be searched only in the
    // files of the use and of the construction, so goto went to the construction call
    const lib =
        \\pub const Param = struct { long: []const u8 };
        \\pub fn parse(comptime str: []const u8) [1]Param {
        \\    return .{.{ .long = str[2..] }};
        \\}
        \\pub fn Args(comptime params: []const Param) type {
        \\    var names: [params.len][]const u8 = undefined;
        \\    var types: [params.len]type = undefined;
        \\    for (params, 0..) |p, k| {
        \\        names[k] = p.long[0..p.long.len] ++ "";
        \\        types[k] = bool;
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &@splat(.{}));
        \\}
        \\pub fn Result(comptime params: []const Param) type {
        \\    return struct { args: Args(params) };
        \\}
        \\pub fn run(comptime params: []const Param) Result(params) {
        \\    return undefined;
        \\}
        \\
    ;
    const args =
        \\const lib = @import("lib.zig");
        \\pub const params = lib.parse("--help");
        \\
    ;
    const main =
        \\const lib = @import("lib.zig");
        \\const args = @import("args.zig");
        \\pub fn main() bool {
        \\    const res = lib.run(&args.params);
        \\    return res.args.help;
        \\}
        \\
    ;
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root = try w.vfs.intern(try std.fs.path.join(w.arena.allocator(), &.{ env.std_dir, "std.zig" }));
    const lib_file = (try w.add("/p/lib.zig", lib)).file;
    const args_file = (try w.add("/p/args.zig", args)).file;
    const main_file = (try w.add("/p/main.zig", main)).file;
    try w.setGraph(std_root, &.{.{ .root = main_file, .imports = &.{} }}, &.{
        .{ .file = lib_file, .module = 0, .compile = 0 },
        .{ .file = args_file, .module = 0, .compile = 0 },
        .{ .file = main_file, .module = 0, .compile = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const target = try definition.definition(&r, main_file, @intCast(std.mem.indexOf(u8, main, "args.help").? + 6)) orelse return error.NoDefinition;
    try testing.expectEqual(args_file, target.file);
    try testing.expectEqual(std.mem.indexOf(u8, args, "help").?, target.start);
}

test "goto declaration of a shorthand member of an inline reified enum" {
    const text =
        \\const Mode = @Enum(u8, .exhaustive, &.{ "fast", "slow" }, &.{ 0, 1 });
        \\fn advanced() u64 {
        \\    const mode: Mode = .fast;
        \\    return @intFromEnum(mode);
        \\}
        \\comptime {
        \\    _ = &advanced;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = std.mem.indexOf(u8, text, ".fast").? + 2;
    const t = (try definition.definition(&r, file, @intCast(at))) orelse return error.NoTarget;
    try testing.expectEqual(file, t.file);
    testing.expect(std.mem.startsWith(u8, text[t.start..], "fast\"")) catch |err| {
        std.debug.print("target `{s}`\n", .{text[t.start..t.end]});
        return err;
    };
}

test "goto declaration of reified enum members named by string literals or @typeInfo" {
    // Members of enums reified by `@Enum` (such as SyntaxKind) used to have no goto target
    const kind_text =
        \\const Base = enum { alpha, beta };
        \\const extra = [_][:0]const u8{ "gamma", "delta" };
        \\pub const Kind = blk: {
        \\    const tags = @typeInfo(Base).@"enum".field_names;
        \\    const local = [_][:0]const u8{"epsilon"};
        \\    const more = extra;
        \\    var names: [tags.len + more.len + local.len][:0]const u8 = undefined;
        \\    var values: [names.len]u8 = undefined;
        \\    for (tags, 0..) |name, i| names[i] = name;
        \\    for (more, tags.len..) |name, i| names[i] = name;
        \\    for (local, tags.len + more.len..) |name, i| names[i] = name;
        \\    for (&values, 0..) |*v, i| v.* = i;
        \\    break :blk @Enum(u8, .exhaustive, &names, &values);
        \\};
        \\
    ;
    const text =
        \\const Kind = @import("kind.zig").Kind;
        \\const Filter = struct { only: ?Kind = null };
        \\fn f(k: Kind) bool {
        \\    const filter: Filter = .{ .only = .epsilon };
        \\    _ = filter;
        \\    return k == .gamma or k == .beta or k == Kind.delta;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const kind = (try w.add("/p/kind.zig", kind_text)).file;
    const file = (try w.add("/p/main.zig", text)).file;
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        // String literal in the file of the reified type (through the local alias `more` with the
        // same value)
        .{ "gamma or", "gamma\", \"delta" },
        // Local constant in the member containing the construction; the result type is optional
        .{ "epsilon }", "epsilon\"}" },
        // Member names given by `@typeInfo(Base)`: members of Base
        .{ "beta or", "beta };" },
        // Access through the type
        .{ "delta;", "delta\" };" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.definition(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        try testing.expectEqual(kind, t.file);
        testing.expect(std.mem.startsWith(u8, kind_text[t.start..], c[1])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, kind_text[t.start..t.end] });
            return err;
        };
    }
}

test "goto on fields of anonymous struct values and in initializers of reified structs" {
    // Prevents an empty result for `anon.first` and for `.alpha` in initializers of `@Struct` types
    const text =
        \\const std = @import("std");
        \\const S = @Struct(.auto, null, &.{ "alpha", "beta" }, &.{ u32, bool }, &@splat(.{}));
        \\const Color = enum { red, green, blue };
        \\test "reified" {
        \\    const s: S = .{ .alpha = 1, .beta = true };
        \\    const s2 = S{ .alpha = 2, .beta = false };
        \\    const arr = std.EnumArray(Color, u32).init(.{ .red = 1, .green = 2, .blue = 3 });
        \\    const fs: std.enums.EnumFieldStruct(Color, u8, 0) = .{ .blue = 7 };
        \\    _ = .{ s, s2, arr, fs };
        \\}
        \\test "anon" {
        \\    const anon = .{ .first = @as(u32, 1), .second = true };
        \\    _ = anon.first;
        \\    const cases = .{ .{ .input = "a", .expected = @as(u32, 1) }, .{ .input = "b", .expected = @as(u32, 2) } };
        \\    inline for (cases) |case| {
        \\        _ = case.input;
        \\    }
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = struct {
        fn of(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, text, needle).?);
        }
    }.of;
    for ([_]struct { []const u8, []const u8 }{
        .{ "alpha = 1", "alpha\", \"beta" },
        .{ "alpha = 2", "alpha\", \"beta" },
        .{ "red = 1", "red, green" },
        .{ "blue = 7", "blue }" },
        .{ "first;", "first = @as" },
    }) |c| {
        const t = try definition.definition(&r, file, at(c[0])) orelse {
            std.debug.print("`{s}`: no target\n", .{c[0]});
            return error.NoTarget;
        };
        try testing.expectEqual(file, t.file);
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[1])) catch |err| {
            std.debug.print("`{s}`: target `{s}`\n", .{ c[0], text[t.start..t.end] });
            return err;
        };
    }
    // One target per item of the tuple the loop iterates
    const targets = try definition.definitionTargets(&r, file, at("input;"));
    try testing.expectEqual(2, targets.len);
    try testing.expectEqual(at("input = \"a\""), targets[0].start);
    try testing.expectEqual(at("input = \"b\""), targets[1].start);
}

test "hover names a reified type after the constant it initializes" {
    // Types reified outside functions used to be shown by content as an anonymous `enum { ... }`
    const text =
        \\const Kind = blk: {
        \\    break :blk @Enum(u8, .exhaustive, &.{ "alpha", "beta" }, &.{ 0, 1 });
        \\};
        \\fn f(k: Kind) void {
        \\    _ = .{ k, Kind.beta };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const param = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "k, Kind").?), &.{}, .list)).?;
    try testing.expectEqualStrings("```zig\nk: Kind\n```", param.text);
    const member = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "beta }").?), &.{}, .list)).?;
    try testing.expect(std.mem.indexOf(u8, member.text, "enum {") == null);
}

test "member completion of reified, tuple and anonymous struct types" {
    const text =
        \\fn Fields() type { return @Enum(u8, .exhaustive, &.{ "alpha", "beta" }, &.{ 0, 1 }); }
        \\fn run() void {
        \\    const F = Fields();
        \\    const t = .{ @as(u8, 1), true };
        \\    const a = .{ .name = @as(u32, 1), .@"type" = u8 };
        \\    _ = .{ F.alpha, t.len, a.name };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "F.alpha", "alpha beta" },
        // Tuple fields are not valid identifiers and are inserted in quoted form
        .{ "t.len", "@\"0\" @\"1\" len" },
        // Fields with the same name as a primitive type can be accessed directly
        .{ "a.name", "name type" },
    };
    for (cases) |c| {
        const at: u32 = @intCast(std.mem.indexOf(u8, text, c[0]).? + std.mem.indexOfScalar(u8, c[0], '.').? + 1);
        const items = (try completion.complete(&r, file, at, .{ .auto_import = false })).items;
        var labels: std.ArrayList([]const u8) = .empty;
        for (items) |it| try labels.append(w.arena.allocator(), it.label);
        testing.expectEqualStrings(c[1], try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
            std.debug.print("completion after `{s}`\n", .{c[0]});
            return err;
        };
    }
}

/// Completes at the position after the last `.` of `needle` in `text`; the labels of the items
/// are joined with spaces
fn memberLabels(w: *World, r: *resolve.Resolver, file: FileId, text: []const u8, needle: []const u8) ![]const u8 {
    const at: u32 = @intCast(std.mem.indexOf(u8, text, needle).? + std.mem.lastIndexOfScalar(u8, needle, '.').? + 1);
    const items = (try completion.complete(r, file, at, .{ .auto_import = false })).items;
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    return std.mem.join(w.arena.allocator(), " ", labels.items);
}

test "imported zon files are values with member completion and hover" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/position.zon",
        \\.{
        \\    .x = 1,
        \\    .y = 2,
        \\    .name = "origin",
        \\    .tags = .{ .a, .b },
        \\    .inner = .{ .z = 1.5, .on = true },
        \\}
        \\
    );
    const text =
        \\const pos = @import("position.zon");
        \\fn run() void {
        \\    _ = .{ pos.x, @import("position.zon").y, pos.inner.z, pos.tags.len, pos.name };
        \\}
        \\
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const completions = [_]struct { []const u8, []const u8 }{
        .{ "pos.x", "x y name tags inner" },
        .{ "@import(\"position.zon\").y", "x y name tags inner" },
        .{ "inner.z", "z on" },
        .{ "tags.len", "@\"0\" @\"1\" len" },
    };
    for (completions) |c| {
        testing.expectEqualStrings(c[1], try memberLabels(&w, &r, file, text, c[0])) catch |err| {
            std.debug.print("completion after `{s}`\n", .{c[0]});
            return err;
        };
    }
    const hovers = [_]struct { []const u8, []const u8 }{
        .{ "pos =", "const pos = .{\n    .x = 1,\n    .y = 2,\n    .name = \"origin\",\n    .tags = .{ .a, .b },\n    .inner = .{ .z = 1.5, .on = true },\n}" },
        .{ "x, @", "comptime_int = 1" },
        .{ "y, pos", "comptime_int = 2" },
        .{ "z, pos", "comptime_float = 1.5" },
        .{ "name }", "*const [6:0]u8 = \"origin\"" },
    };
    for (hovers) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}\n```", .{c[1]}), info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "goto from fields of imported zon values to the names in the zon file" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const pos_text =
        \\.{
        \\    .x = 1,
        \\    .inner = .{ .z = 1.5 },
        \\    .same = .{ .v = 1 },
        \\    .other = .{ .v = 1 },
        \\    .list = .{ .{ .item = 1 }, .{ .item = 2 } },
        \\}
        \\
    ;
    const twin_text = ".{ .x = 1 }\n";
    const pos = (try w.add("/p/pos.zon", pos_text)).file;
    const twin_a = (try w.add("/p/twin_a.zon", twin_text)).file;
    const twin_b = (try w.add("/p/twin_b.zon", twin_text)).file;
    const text =
        \\const pos = @import("pos.zon");
        \\const twin_a = @import("twin_a.zon");
        \\const twin_b = @import("twin_b.zon");
        \\const alias = pos;
        \\const same = pos.same;
        \\fn read(v: anytype) comptime_int {
        \\    return v.x;
        \\}
        \\fn run() void {
        \\    const copy = pos;
        \\    const inner = pos.inner;
        \\    const ptr = &pos;
        \\    _ = .{ pos.x, @import("pos.zon").x, alias.x, copy.x, ptr.x };
        \\    _ = .{ pos.inner, inner.z, same.v, pos.other.v, pos.list[1].item };
        \\    _ = .{ twin_a.x, twin_b.x, read(pos), read(twin_b) };
        \\    inline for (pos.list) |entry| _ = entry.item;
        \\}
        \\
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const x_in_pos: u32 = @intCast(std.mem.indexOf(u8, pos_text, "x =").?);
    const x_in_twin: u32 = @intCast(std.mem.indexOf(u8, twin_text, "x =").?);
    const cases = [_]struct { use: []const u8, file: FileId, start: u32 }{
        .{ .use = "pos.x", .file = pos, .start = x_in_pos },
        .{ .use = "@import(\"pos.zon\").x", .file = pos, .start = x_in_pos },
        .{ .use = "alias.x", .file = pos, .start = x_in_pos },
        .{ .use = "copy.x", .file = pos, .start = x_in_pos },
        .{ .use = "ptr.x", .file = pos, .start = x_in_pos },
        .{ .use = "pos.inner", .file = pos, .start = @intCast(std.mem.indexOf(u8, pos_text, "inner =").?) },
        .{ .use = "inner.z", .file = pos, .start = @intCast(std.mem.indexOf(u8, pos_text, "z =").?) },
        // Literals with the same contents in one file, or in two, are different types
        .{ .use = "same.v", .file = pos, .start = @intCast(std.mem.indexOf(u8, pos_text, "v = 1").?) },
        .{ .use = "pos.other.v", .file = pos, .start = @intCast(std.mem.lastIndexOf(u8, pos_text, "v = 1").?) },
        .{ .use = "twin_a.x", .file = twin_a, .start = x_in_twin },
        .{ .use = "twin_b.x", .file = twin_b, .start = x_in_twin },
        .{ .use = "[1].item", .file = pos, .start = @intCast(std.mem.indexOf(u8, pos_text, "item = 2").?) },
    };
    for (cases) |c| {
        const name_at = std.mem.indexOf(u8, text, c.use).? + c.use.len - 1;
        const t = try definition.definition(&r, file, @intCast(name_at)) orelse {
            std.debug.print("`{s}`: no target\n", .{c.use});
            return error.NoTarget;
        };
        testing.expectEqual(c.file, t.file) catch |err| {
            std.debug.print("`{s}`: wrong file\n", .{c.use});
            return err;
        };
        testing.expectEqual(c.start, t.start) catch |err| {
            std.debug.print("`{s}`: wrong position\n", .{c.use});
            return err;
        };
    }
    // Every instance of a generic function, and every item of a tuple being iterated
    try testing.expectEqualSlices(definition.Target, &.{
        .{ .file = pos, .start = x_in_pos, .end = x_in_pos + 1 },
        .{ .file = twin_b, .start = x_in_twin, .end = x_in_twin + 1 },
    }, try definition.definitionTargets(&r, file, @intCast(std.mem.indexOf(u8, text, "v.x").? + 2)));
    const first_item: u32 = @intCast(std.mem.indexOf(u8, pos_text, "item = 1").?);
    const second_item: u32 = @intCast(std.mem.indexOf(u8, pos_text, "item = 2").?);
    try testing.expectEqualSlices(definition.Target, &.{
        .{ .file = pos, .start = first_item, .end = first_item + 4 },
        .{ .file = pos, .start = second_item, .end = second_item + 4 },
    }, try definition.definitionTargets(&r, file, @intCast(std.mem.indexOf(u8, text, "entry.item").? + 6)));
}

test "goto from an imported build.zig.zon to its field" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const manifest_text = ".{ .name = .demo, .version = \"1.2.3\" }\n";
    const manifest_file = (try w.add("/p/build.zig.zon", manifest_text)).file;
    const text = "const version = @import(\"build.zig.zon\").version;\n";
    const file = (try w.add("/p/build.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const t = (try definition.definition(&r, file, @intCast(std.mem.lastIndexOf(u8, text, "version").?))).?;
    try testing.expectEqual(manifest_file, t.file);
    try testing.expectEqual(std.mem.indexOf(u8, manifest_text, "version").?, t.start);
}

test "zon imports with a result type take the result type" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/cfg.zon", ".{ .port = 8080, .host = \"localhost\" }");
    _ = try w.add("/p/n.zon", "5");
    _ = try w.add("/p/level.zon", ".debug");
    const text =
        \\const Cfg = struct { port: u16, host: []const u8, verbose: bool = false };
        \\const Level = enum { debug, info };
        \\const cfg: Cfg = @import("cfg.zon");
        \\const n: u32 = @import("n.zon");
        \\const level: Level = @import("level.zon");
        \\fn portOf(comptime c: Cfg) u16 {
        \\    return c.port;
        \\}
        \\const port = portOf(@import("cfg.zon"));
        \\fn run() void {
        \\    _ = cfg.port;
        \\}
        \\
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    try testing.expectEqualStrings("port host verbose", try memberLabels(&w, &r, file, text, "cfg.port"));
    const hovers = [_]struct { []const u8, []const u8 }{
        .{ "cfg:", "const cfg: Cfg" },
        // The value of a scalar is the same as the result of parsing according to the result type
        .{ "n:", "const n: u32 = 5" },
        .{ "level:", "const level: Level = .debug" },
        // The argument is parsed as `Cfg`, not as the value of an anonymous struct: the value
        // cannot be evaluated
        .{ "port =", "const port: u16" },
    };
    for (hovers) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}\n```", .{c[1]}), info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "zon import values follow edits to the zon file" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/data.zon", ".{ .a = 1 }");
    _ = try w.add("/p/lib.zig", "pub const answer = 42;");
    const text =
        \\const data = @import("data.zon");
        \\const lib = @import("lib.zig");
        \\fn run() void {
        \\    _ = .{ data.a, lib.answer };
        \\}
        \\
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    const steps = [_]struct { []const u8, []const u8 }{
        .{ ".{ .a = 1 }", "a" },
        .{ ".{ .a = 1, .b = .{ 2, 3 } }", "a b" },
        // No value when there are errors (syntax errors, duplicate field names); no guessing
        .{ ".{ .a = 1, .b = ", "" },
        .{ ".{ .a = 1, .a = 2 }", "" },
        .{ ".{ .c = 3 }", "c" },
    };
    for (steps) |step| {
        _ = try w.add("/p/data.zon", step[0]);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        testing.expectEqualStrings(step[1], try memberLabels(&w, &r, file, text, "data.a")) catch |err| {
            std.debug.print("data.zon: `{s}`\n", .{step[0]});
            return err;
        };
        // `.zig` files are still namespaces
        try testing.expectEqualStrings("answer", try memberLabels(&w, &r, file, text, "lib.answer"));
    }
}

const zon_cfg_decls =
    \\const Cfg = struct { port: u16, host: []const u8, verbose: bool = false, level: Level = .info, server: Server = .{} };
    \\const Level = enum { debug, info };
    \\const Server = struct { threads: u8 = 1, backlog: u32 = 128 };
;

/// The completion labels at the cursor
fn completionAt(w: *World, at: World.Added) ![]const u8 {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    var labels: std.ArrayList([]const u8) = .empty;
    for ((try completion.complete(&r, at.file, at.cursor, .{ .auto_import = false })).items) |it| try labels.append(w.arena.allocator(), it.label);
    return std.mem.join(w.arena.allocator(), " ", labels.items);
}

/// The completion at the cursor is `expected` both when the same literal (containing `<|>`) is a
/// `.zon` file imported by `const cfg: Cfg = @import("cfg.zon");` and when it is the value of
/// `const lit: Cfg = <literal>;` in a `.zig` file
fn expectZonCompletionLikeZig(literal: []const u8, expected: []const u8) !void {
    for ([_]bool{ true, false }) |in_zon| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const a = w.arena.allocator();
        const at = if (in_zon) blk: {
            _ = try w.fixture(try std.fmt.allocPrint(a, "//- /p/main.zig module:app\n{s}\nconst cfg: Cfg = @import(\"cfg.zon\");", .{zon_cfg_decls}));
            break :blk try w.add("/p/cfg.zon", literal);
        } else try w.add("/p/main.zig", try std.fmt.allocPrint(a, "{s}\nconst lit: Cfg = {s};\n", .{ zon_cfg_decls, literal }));
        testing.expectEqualStrings(expected, try completionAt(&w, at)) catch |err| {
            std.debug.print("literal `{s}` in {s}\n", .{ literal, if (in_zon) "zon" else "zig" });
            return err;
        };
    }
}

test "zon files take the result type of their typed imports" {
    // Field names, enum literals, nested initializer lists: the same results as for the same
    // literal in a `.zig` file
    try expectZonCompletionLikeZig(".{ .port = 8080, .<|> }", "host verbose level server");
    try expectZonCompletionLikeZig(".{ .port = 8080, .level = .<|> }", "debug info");
    try expectZonCompletionLikeZig(".{ .port = 8080, .server = .{ .threads = 2, .<|> } }", "backlog");

    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const main = (try w.fixture("//- /p/main.zig module:app\n" ++ zon_cfg_decls ++ "\nconst cfg: Cfg = @import(\"cfg.zon\");")).file("/p/main.zig");
    const zon_text =
        \\.{
        \\    .port = 8080,
        \\    .host = "localhost",
        \\    .level = .debug,
        \\    .server = .{ .threads = 4 },
        \\}
        \\
    ;
    const zon_file = (try w.add("/p/cfg.zon", zon_text)).file;
    try testing.expectEqualStrings(
        \\.{
        \\    .port: u16 = 8080,
        \\    .host: []const u8 = "localhost",
        \\    .level: Level = .debug,
        \\    .server: Server = .{ .threads: u8 = 4 },
        \\}
        \\
    , try inlaid(&w, zon_file, zon_text, .{ .types = false, .parameters = false }));

    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const main_text = (try ctx.get(database.syntax.SourceText, main)).text;
    // A field name jumps to the declaration of the field in the result type, an enum literal to
    // the enum member
    const jumps = [_]struct { []const u8, []const u8 }{
        .{ "port", "port:" },
        .{ "threads", "threads:" },
        .{ "debug", "debug," },
    };
    for (jumps) |j| {
        const t = try definition.definition(&r, zon_file, @intCast(std.mem.indexOf(u8, zon_text, j[0]).?)) orelse return error.NoDefinition;
        try testing.expectEqual(main, t.file);
        try testing.expectEqual(std.mem.indexOf(u8, main_text, j[1]).?, t.start);
    }
    // The references of a field include the field name in the `.zon` file
    const def = try definition.defAt(&r, main, @intCast(std.mem.indexOf(u8, main_text, "port:").?)) orelse return error.NoDefinition;
    const refs = try search.findReferences(&r, def, .{ .scope = &.{ main, zon_file } });
    try testing.expectEqual(2, refs.len);
    try testing.expectEqual(zon_file, refs[1].file);
    try testing.expectEqual(std.mem.indexOf(u8, zon_text, "port").?, refs[1].start);
}

test "references do not look into zon files without a result type" {
    // Nothing in an untyped `.zon` file refers to a declaration, even where the values cannot be
    // inferred (`foo` is not a ZON value): such files leave no uncertain references
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const main_text = "const Cfg = struct { port: u16 };\nconst raw = @import(\"cfg.zon\");\n";
    const main = (try w.fixture("//- /p/main.zig module:app\n" ++ main_text)).file("/p/main.zig");
    const zon_file = (try w.add("/p/cfg.zon", ".{ .port = foo, .other = .{ .port = 1 } }\n")).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const def = try definition.defAt(&r, main, @intCast(std.mem.indexOf(u8, main_text, "port:").?)) orelse return error.NoDefinition;
    var uncertain: ?search.Reference = null;
    const refs = try search.findReferences(&r, def, .{ .scope = &.{ main, zon_file }, .uncertain = &uncertain });
    try testing.expectEqual(1, refs.len);
    try testing.expectEqual(null, uncertain);
}

test "zon files complete only what the compiler parses, not declarations" {
    // `.default` is a decl literal in a `.zig` file; the compiler rejects it in ZON, where only an
    // enum's names and the tags of a union without a payload are enum literals
    const decls =
        \\const Level = enum { debug, info, pub const default: Level = .info; pub fn make() Level { return .info; } };
        \\const Inner = struct { n: u8 = 0, pub const zero: Inner = .{}; pub fn init() Inner { return .{}; } };
        \\const Tag = union(enum) { a: u8, b: void, pub const none: Tag = .b; };
        \\const Cfg = struct { level: Level = .info, inner: Inner = .{}, tag: Tag = .b, opt: ?Level = null, ptr: *const Level = &.info, arr: [1]Level = .{.info}, pub const shared: Cfg = .{}; };
        \\
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ ".{ .level = .<|> }", "debug info" },
        .{ ".{ .opt = .<|> }", "debug info" },
        .{ ".{ .ptr = .<|> }", "debug info" },
        .{ ".{ .arr = .{ .<|> } }", "debug info" },
        .{ ".{ .tag = .<|> }", "b" },
        .{ ".{ .inner = .<|> }", "" },
        .{ ".<|>", "" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        _ = try w.fixture("//- /p/main.zig module:app\n" ++ decls ++ "const cfg: Cfg = @import(\"cfg.zon\");\n");
        testing.expectEqualStrings(c[1], try completionAt(&w, try w.add("/p/cfg.zon", c[0]))) catch |err| {
            std.debug.print("`{s}`\n", .{c[0]});
            return err;
        };
    }
    // The same literals in a `.zig` file still offer declarations
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try testing.expectEqualStrings("debug info default make", try completionAt(&w, try w.add("/p/main.zig", decls ++ "const level: Level = .<|>;\n")));
}

test "references find the fields of a zon file whose import sites give several result types" {
    const zon_text = ".{ .x = 1, .e = .red, .other = 2 }\n";
    // Each case: the importing file, the name to search from, and the uses in `cfg.zon`
    const cases = [_]struct { []const u8, []const u8, []const []const u8 }{
        .{ "const S = struct { x: u32, e: E };\nconst E = enum { red };\nconst T = struct { x: u8 };\nconst a: S = @import(\"cfg.zon\");\nconst b: T = @import(\"cfg.zon\");\n", "x: u32", &.{"x ="} },
        .{ "const S = struct { x: u32 };\nconst T = struct { x: u8 };\nconst a: S = @import(\"cfg.zon\");\nconst b: T = @import(\"cfg.zon\");\n", "x: u8", &.{"x ="} },
        // An enum member, reached under one of the types
        .{ "const E = enum { red };\nconst S = struct { x: u32, e: E };\nconst T = struct { x: u8 };\nconst a: S = @import(\"cfg.zon\");\nconst b: T = @import(\"cfg.zon\");\n", "red", &.{"red"} },
        // A generic result type: under each instance of the function
        .{ "const S = struct { x: u32 };\nfn load(comptime T: type) T {\n    return @import(\"cfg.zon\");\n}\nconst a = load(S);\n", "x: u32", &.{"x ="} },
        // A field that none of the types has at that position is not a use
        .{ "const F = struct { x: u8 };\nconst S = struct { y: u32 };\nconst T = struct { z: u8 };\nconst a: S = @import(\"cfg.zon\");\nconst b: T = @import(\"cfg.zon\");\nconst f: F = .{ .x = 1 };\n", "x: u8", &.{} },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const a = w.arena.allocator();
        const main = (try w.fixture(try std.mem.concat(a, u8, &.{ "//- /p/main.zig module:app\n", c[0] }))).file("/p/main.zig");
        const zon_file = (try w.add("/p/cfg.zon", zon_text)).file;
        var ctx = w.db.beginRead(a);
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const def = try definition.defAt(&r, main, @intCast(std.mem.indexOf(u8, c[0], c[1]).?)) orelse return error.NoDefinition;
        var found: std.ArrayList(u32) = .empty;
        for (try search.findReferences(&r, def, .{ .scope = &.{ main, zon_file } })) |ref| if (ref.file == zon_file) try found.append(a, ref.start);
        var expected: std.ArrayList(u32) = .empty;
        for (c[2]) |needle| try expected.append(a, @intCast(std.mem.indexOf(u8, zon_text, needle).?));
        testing.expectEqualSlices(u32, expected.items, found.items) catch |err| {
            std.debug.print("search from `{s}` in:\n{s}\n", .{ c[1], c[0] });
            return err;
        };
    }
}

test "zon files have no result type unless their typed imports agree" {
    const cases = [_]struct { []const u8, []const u8 }{
        // No import site; only an import without a result type
        .{ "", "" },
        .{ "const raw = @import(\"cfg.zon\");", "" },
        // An import site without a result type does not constrain the value
        .{ "const raw = @import(\"cfg.zon\");\nconst cfg: Cfg = @import(\"cfg.zon\");", "host verbose level server" },
        // The import sites agree on the type (including an import inside a function); they disagree
        .{ "const cfg: Cfg = @import(\"cfg.zon\");\nfn load() Cfg {\n    return @import(\"cfg.zon\");\n}", "host verbose level server" },
        .{ "const cfg: Cfg = @import(\"cfg.zon\");\nconst server: Server = @import(\"cfg.zon\");", "" },
        // Pointers and optionals around the same type parse the value the same way
        .{ "const cfg: Cfg = @import(\"cfg.zon\");\nconst p: *const Cfg = @import(\"cfg.zon\");\nconst o: ?Cfg = @import(\"cfg.zon\");", "host verbose level server" },
        .{ "const p: *const Cfg = @import(\"cfg.zon\");\nconst s: *const Server = @import(\"cfg.zon\");", "" },
        // The result type depends on a generic parameter
        .{ "fn load(comptime T: type) T {\n    return @import(\"cfg.zon\");\n}", "" },
        // A branch known at comptime not to execute is not compiled
        .{ "const cfg: Cfg = @import(\"cfg.zon\");\ncomptime {\n    if (false) {\n        const s: Server = @import(\"cfg.zon\");\n        _ = s;\n    }\n}", "host verbose level server" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        _ = try w.fixture(try std.fmt.allocPrint(w.arena.allocator(), "//- /p/main.zig module:app\n{s}\n{s}", .{ zon_cfg_decls, c[0] }));
        const at = try w.add("/p/cfg.zon", ".{ .port = 8080, .<|> }");
        testing.expectEqualStrings(c[1], try completionAt(&w, at)) catch |err| {
            std.debug.print("importer:\n{s}\n", .{c[0]});
            return err;
        };
    }
}

test "zon values take pointer and slice result types like the compiler" {
    // The compiler parses the value of a single-item pointer as the pointee type, and the value of
    // a slice is an array literal (a `.zig` file needs `&.{ ... }`)
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "const cfg: *const Cfg = @import(\"cfg.zon\");", ".{ .port = 8080, .<|> }", "host verbose level server" },
        .{ "const cfg: ?*const Cfg = @import(\"cfg.zon\");", ".{ .port = 8080, .level = .<|> }", "debug info" },
        .{ "const cfgs: []const Cfg = @import(\"cfg.zon\");", ".{ .{ .port = 1 }, .{ .port = 2, .<|> } }", "host verbose level server" },
        .{ "const cfgs: []const Cfg = @import(\"cfg.zon\");", ".{ .{ .port = 1, .level = .<|> } }", "debug info" },
        .{ "const Group = struct { servers: []const Server };\nconst g: Group = @import(\"cfg.zon\");", ".{ .servers = .{ .{ .threads = 2, .<|> } } }", "backlog" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        _ = try w.fixture(try std.fmt.allocPrint(w.arena.allocator(), "//- /p/main.zig module:app\n{s}\n{s}", .{ zon_cfg_decls, c[0] }));
        const at = try w.add("/p/cfg.zon", c[1]);
        testing.expectEqualStrings(c[2], try completionAt(&w, at)) catch |err| {
            std.debug.print("importer:\n{s}\n", .{c[0]});
            return err;
        };
    }

    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.fixture("//- /p/main.zig module:app\n" ++ zon_cfg_decls ++ "\nconst Group = struct { servers: []const Server };\nconst g: *const Group = @import(\"cfg.zon\");");
    const zon_text = ".{ .servers = .{ .{ .threads = 2 } } }";
    const zon_file = (try w.add("/p/cfg.zon", zon_text)).file;
    try testing.expectEqualStrings(".{ .servers: []const Server = .{ .{ .threads: u8 = 2 } } }", try inlaid(&w, zon_file, zon_text, .{ .types = false, .parameters = false }));
}

test "zon result types follow the importers across files and edits" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.fixture(
        \\//- /p/main.zig module:app
        \\pub const Cfg = struct { port: u16, host: []const u8 = "" };
        \\const cfg: Cfg = @import("conf/cfg.zon");
        \\//- /p/other.zig in:app
        \\const Cfg = @import("main.zig").Cfg;
        \\const cfg: Cfg = @import("conf/cfg.zon");
    );
    var at = try w.add("/p/conf/cfg.zon", ".{ .port = 8080, .<|> }");
    try testing.expectEqualStrings("host", try completionAt(&w, at));
    const steps = [_]struct { path: []const u8, text: []const u8, labels: []const u8 }{
        // Change the type in the importer
        .{ .path = "main", .text = "pub const Cfg = struct { port: u16, name: []const u8 = \"\", debug: bool = false };\nconst cfg: Cfg = @import(\"conf/cfg.zon\");", .labels = "name debug" },
        // Change the content of the `.zon` file
        .{ .path = "zon", .text = ".{ .port = 8080, .name = \"x\", .<|> }", .labels = "debug" },
        // One import site switches to another type
        .{ .path = "other", .text = "const cfg: u32 = @import(\"conf/cfg.zon\");", .labels = "" },
        .{ .path = "other", .text = "const cfg = @import(\"conf/cfg.zon\");", .labels = "debug" },
    };
    for (steps) |step| {
        if (std.mem.eql(u8, step.path, "main")) {
            _ = try w.add("/p/main.zig", step.text);
        } else if (std.mem.eql(u8, step.path, "other")) {
            _ = try w.add("/p/other.zig", step.text);
        } else at = try w.add("/p/conf/cfg.zon", step.text);
        testing.expectEqualStrings(step.labels, try completionAt(&w, at)) catch |err| {
            std.debug.print("after editing {s}: `{s}`\n", .{ step.path, step.text });
            return err;
        };
    }
}

test "zig-analyzer.zon settings are completed from the schema" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ ".{ .<|> }", "build diagnostics imports naming" },
        // Settings already given are not listed again
        .{ ".{ .build = .{}, .<|> }", "diagnostics imports naming" },
        .{ ".{ .build = .{ .<|> } }", "args" },
        .{ ".{ .diagnostics = .{ .steps = .{}, .<|> } }", "compiler" },
        .{ ".{ .naming = .{ .rules = .{ .type = false, .<|> } } }", "type_function function namespace value field" },
        // Values: the names of an enum, and booleans
        .{ ".{ .imports = .{ .derived = .<|> } }", "with_import separate" },
        .{ ".{ .imports = .{ .sort = .na<|> } }", "path name" },
        .{ ".{\n    .imports = .{\n        .sort =\n            .<|>\n    },\n}", "path name" },
        .{ ".{ .naming = .{ .enable = <|> } }", "true false" },
        .{ ".{ .naming = .{ .rules = .{ .field = t<|> } } }", "true false" },
        // Neither applies, or the position is outside the schema
        .{ ".{ .imports = .{ .sort = <|> } }", "" },
        .{ ".{ .naming = .{ .enable = .<|> } }", "" },
        .{ ".{ .build = .{ .args = .{ .<|> } } }", "" },
        .{ ".{ .unknown = .{ .<|> } }", "" },
        .{ ".{ .unknown = .<|> }", "" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const at = try w.add("/p/zig-analyzer.zon", c[0]);
        testing.expectEqualStrings(c[1], try completionAt(&w, at)) catch |err| {
            std.debug.print("zig-analyzer.zon: `{s}`\n", .{c[0]});
            return err;
        };
    }
    // Other `.zon` files are not affected
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try testing.expectEqualStrings("", try completionAt(&w, try w.add("/p/other.zon", ".{ .<|> }")));
    try testing.expectEqualStrings("", try completionAt(&w, try w.add("/p/more.zon", ".{ .imports = .{ .sort = .<|> } }")));
}

test "zig-analyzer.zon settings have the descriptions of the default settings" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\.{
        \\    .imports = .{ .sort = .name },
        \\    .naming = .{ .enable = true, .rules = .{ .field = false } },
        \\    .build = .{ .nope = 1 },
        \\    .log = .{ .level = .debug },
        \\}
        \\
    ;
    const file = (try w.add("/p/zig-analyzer.zon", text)).file;
    const other = (try w.add("/p/other.zon", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "imports", "How top-level imports are arranged" },
        .{ "sort", "Order within a group.\n\n- `.path`: By what is imported" },
        .{ "name }", "By declaration name." },
        .{ "enable", "Hint names that do not follow the Names section" },
        .{ "rules", "Turn individual rules on or off" },
        .{ "field", "Fields and enum members, by the type of the field.\n\nDefault: `true`" },
        // Values without a description, and what the file cannot set
        .{ "true", null },
        .{ "nope", null },
        .{ "log", null },
        .{ "level", null },
    };
    for (cases) |c| {
        const offset: u32 = @intCast(std.mem.indexOf(u8, text, c[0]).?);
        const info = try hover.hover(&r, file, offset, &.{}, .list);
        const got = if (info) |i| i.text else "";
        if (c[1]) |want| {
            testing.expect(std.mem.startsWith(u8, got, want)) catch |err| {
                std.debug.print("hover at `{s}`: {s}\n", .{ c[0], got });
                return err;
            };
            if (try hover.hover(&r, other, offset, &.{}, .list)) |i| try testing.expect(!std.mem.startsWith(u8, i.text, want));
        } else {
            testing.expect(std.mem.indexOf(u8, got, "\n\nDefault") == null and !std.mem.startsWith(u8, got, "How")) catch |err| {
                std.debug.print("hover at `{s}`: {s}\n", .{ c[0], got });
                return err;
            };
        }
    }
    const with_default = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "sort").?), &.{}, .list)).?.text;
    try testing.expect(std.mem.indexOf(u8, with_default, "\n\nDefault: `.path`\n\nExample:\n\n```zig\n.sort = .name,\n```") != null);
}

test "zig-analyzer.zon completions have the descriptions of the default settings" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ ".{ .<|> }", "build", "```zig\n.build = .{\n    .args = " },
        .{ ".{ .imports = .{ .sort = .<|> } }", "name", "By declaration name." },
        .{ ".{ .imports = .{ .derived = .<|> } }", "separate", "In a last group of their own." },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const at = try w.add("/p/zig-analyzer.zon", c[0]);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const items = (try completion.complete(&r, at.file, at.cursor, .{ .auto_import = false })).items;
        const item = for (items) |it| {
            if (std.mem.eql(u8, it.label, c[1])) break it;
        } else return error.NoItem;
        try testing.expect(std.mem.indexOf(u8, item.doc.?, c[2]) != null);
    }
}

test "build.zig.zon fields are completed from the schema" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ ".{ .<|> }", "name fingerprint version minimum_zig_version dependencies paths" },
        // Fields already given are not listed again
        .{ ".{ .name = .demo, .version = \"0.1.0\", .<|> }", "fingerprint minimum_zig_version dependencies paths" },
        // The `url` and `path` of a dependency are mutually exclusive; dependencies can have any
        // name
        .{ ".{ .dependencies = .{ .foo = .{ .<|> } } }", "url hash path lazy" },
        .{ ".{ .dependencies = .{ .foo = .{ .url = \"https://example.com/foo.tar.gz\", .<|> } } }", "hash lazy" },
        // A path-based dependency has no hash, and a hash belongs to a fetched one
        .{ ".{ .dependencies = .{ .@\"foo-bar\" = .{ .path = \"libs/foo\", .<|> } } }", "lazy" },
        .{ ".{ .dependencies = .{ .foo = .{ .hash = \"abc\", .<|> } } }", "url lazy" },
        // Dependency names, elements of `.paths`, field values, and objects outside the schema
        .{ ".{ .dependencies = .{ .<|> } }", "" },
        .{ ".{ .paths = .{ .<|> } }", "" },
        .{ ".{ .name = .<|> }", "" },
        .{ ".{ .dependencies = .{ .foo = .{ .url = \"u\", .extra = .{ .<|> } } } }", "" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const at = try w.add("/p/build.zig.zon", c[0]);
        testing.expectEqualStrings(c[1], try completionAt(&w, at)) catch |err| {
            std.debug.print("build.zig.zon: `{s}`\n", .{c[0]});
            return err;
        };
    }

    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const at = try w.add("/p/build.zig.zon", ".{ .<|> }");
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const first = (try completion.complete(&r, at.file, at.cursor, .{ .auto_import = false })).items[0];
    try testing.expectEqual(.field, first.kind);
    try testing.expect(std.mem.startsWith(u8, first.doc.?, "Enum literal. Required."));
}

test "build.zig.zon uses the schema only without a result type" {
    const schema = "name fingerprint version minimum_zig_version dependencies paths";
    const typed = "const M = struct { a: u8, b: u8 };\nconst m: M = @import(\"build.zig.zon\");";
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        // Imported without a result type, as build scripts usually do
        .{ "/p/build.zig.zon", "//- /p/main.zig module:app\nconst zon = @import(\"build.zig.zon\");", schema },
        // With a result type, the file is inferred with that type
        .{ "/p/build.zig.zon", "//- /p/main.zig module:app\n" ++ typed, "a b" },
        // Import sites are searched in the files of the module graph and in the user's source files
        // under the workspace roots, which include build scripts
        .{ "/p/build.zig.zon", "//- /p/main.zig module:app\n//- /p/build.zig\n" ++ typed, "a b" },
        // `.zon` files with other names don't use the schema
        .{ "/p/cfg.zon", "//- /p/main.zig module:app\nconst zon = @import(\"cfg.zon\");", "" },
        .{ "/p/sub/build.zig.zon.zig", "//- /p/main.zig module:app\n", "" },
    };
    inline for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        try w.setWorkspaceFiles((try w.fixture(c[1])).files);
        const at = try w.add(c[0], ".{ .<|> }");
        testing.expectEqualStrings(c[2], try completionAt(&w, at)) catch |err| {
            std.debug.print("{s} imported by:\n{s}\n", .{ c[0], c[1] });
            return err;
        };
    }
}

test "build.zig.zon fields have the official documentation" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\.{
        \\    .name = .demo,
        \\    .@"version" = "0.1.0",
        \\    .dependencies = .{
        \\        .foo = .{ .url = "https://example.com/foo.tar.gz", .hash = "abc", .lazy = true },
        \\        .paths = .{ .path = "libs/paths" },
        \\    },
        \\    .paths = .{ "build.zig", .{ .name = 1 } },
        \\    .unknown = .{ .url = "u" },
        \\}
        \\
    ;
    const file = (try w.add("/p/build.zig.zon", text)).file;
    const cfg = (try w.add("/p/cfg.zon", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "name =", "Enum literal. Required." },
        .{ "@\"version\"", "String. Required." },
        .{ "dependencies", "Struct." },
        .{ "url = \"https://", "String.\n\nWhen updating" },
        .{ "hash", "String.\n\n[multihash]" },
        .{ "lazy", "Boolean." },
        // A dependency named `paths` and the `path` in it
        .{ "path = ", "String.\n\nWhen this is provided" },
        .{ "paths = .{ \"", "List. Required." },
        // Dependency names, values, and fields and objects outside the schema
        .{ "foo", null },
        .{ "paths = .{ .path", null },
        .{ "demo", null },
        .{ "name = 1", null },
        .{ "unknown", null },
        .{ "url = \"u\"", null },
    };
    for (cases) |c| {
        const offset: u32 = @intCast(std.mem.indexOf(u8, text, c[0]).?);
        const info = try hover.hover(&r, file, offset, &.{}, .list);
        const other = try hover.hover(&r, cfg, offset, &.{}, .list);
        const got = if (info) |i| i.text else "";
        if (c[1]) |want| {
            testing.expect(std.mem.startsWith(u8, got, want)) catch |err| {
                std.debug.print("hover at `{s}`: {s}\n", .{ c[0], got });
                return err;
            };
            try testing.expectEqual(offset, info.?.start);
            // `.zon` files with other names have no schema documentation
            try testing.expectEqual(null, other);
        } else {
            // Outside the schema, the same as in other `.zon` files
            testing.expectEqualStrings(if (other) |o| o.text else "", got) catch |err| {
                std.debug.print("hover at `{s}`\n", .{c[0]});
                return err;
            };
        }
    }
}

/// A build root: `build.zig.zon` and some files and directories (entries starting with `.` and
/// `zig-out` are not listed)
const ManifestRoot = struct {
    tmp: testing.TmpDir,
    dir: [:0]const u8,

    fn create() !ManifestRoot {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        // The build output, the fetched packages, and the cache are never offered as paths
        for ([_][]const u8{ "src/util", "libs/foo", "zig-out/bin", "zig-pkg/dep-0.0.1-abc", ".zig-cache" }) |d| try tmp.dir.createDirPath(testing.io, d);
        for ([_][]const u8{ "build.zig", "build.zig.zon", "README.md", ".gitignore", "src/main.zig", "src/util/a.zig", "libs/foo/build.zig.zon" }) |f| {
            try tmp.dir.writeFile(testing.io, .{ .sub_path = f, .data = "" });
        }
        return .{ .tmp = tmp, .dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator) };
    }

    fn deinit(m: *ManifestRoot) void {
        testing.allocator.free(m.dir);
        m.tmp.cleanup();
    }

    /// Uses `text` as the content of its `build.zig.zon`
    fn add(m: ManifestRoot, w: *World, text: []const u8) !World.Added {
        return w.addNative(try std.fs.path.join(w.arena.allocator(), &.{ m.dir, "build.zig.zon" }), text);
    }
};

test "build.zig.zon paths are completed relative to the build root" {
    var root: ManifestRoot = try .create();
    defer root.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        // Elements of `.paths`: files and directories
        .{ ".{ .paths = .{ \"<|>\" } }", "README.md build.zig build.zig.zon libs src" },
        .{ ".{ .paths = .{ \"build.zig\", \"src/<|>\" } }", "src/main.zig src/util" },
        .{ ".{ .paths = .{ \"src/util/a<|>\" } }", "src/util/a.zig" },
        // The `.path` of a dependency: directories only
        .{ ".{ .dependencies = .{ .foo = .{ .path = \"<|>\" } } }", "libs src" },
        .{ ".{ .dependencies = .{ .foo = .{ .path = \"libs/<|>\" } } }", "libs/foo" },
        // Unclosed strings
        .{ ".{\n    .paths = .{ \"build.zig\", \"sr<|>\n    },\n}", "README.md build.zig build.zig.zon libs src" },
        .{ ".{\n    .dependencies = .{ .foo = .{ .path = \"li<|>\n    } },\n}", "libs src" },
        // Strings that are not paths
        .{ ".{ .version = \"<|>\" }", "" },
        .{ ".{ .dependencies = .{ .foo = .{ .url = \"<|>\" } } }", "" },
        .{ ".{ .paths = .{ .{ .path = \"<|>\" } } }", "" },
        .{ ".{ .other = .{ \"<|>\" } }", "" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const at = try root.add(&w, c[0]);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const items = (try completion.complete(&r, at.file, at.cursor, .{ .auto_import = false })).items;
        var labels: std.ArrayList([]const u8) = .empty;
        const text = (try ctx.get(database.syntax.SourceText, at.file)).text;
        for (items) |it| {
            try labels.append(w.arena.allocator(), it.label);
            // The replacement range starts at the start of the string content
            const quote = std.mem.lastIndexOfScalar(u8, text[0..at.cursor], '"').?;
            try testing.expectEqual(quote + 1, it.replace.?.start);
            try testing.expectEqual(at.cursor, it.replace.?.end);
        }
        std.mem.sort([]const u8, labels.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        testing.expectEqualStrings(c[1], try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
            std.debug.print("build.zig.zon: `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "path completion escapes entry names and decodes the typed directory" {
    // `"` and `\` cannot be part of file names on Windows
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "d\"ir", "src" }) |d| try tmp.dir.createDirPath(testing.io, d);
    for ([_][]const u8{ "build.zig", "a\"b.txt", "d\"ir/inner.txt", "d\"ir/inner.zig", "src/bs\\mod.zig", "src/nl\nx.zig" }) |f| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = f, .data = "" });
    }
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "build.zig.zon", ".{ .paths = .{ \"<|>\" } }", "a\\\"b.txt build.zig d\\\"ir src" },
        .{ "build.zig.zon", ".{ .paths = .{ \"d\\\"ir/<|>\" } }", "d\\\"ir/inner.txt d\\\"ir/inner.zig" },
        .{ "build.zig.zon", ".{ .dependencies = .{ .foo = .{ .path = \"<|>\" } } }", "d\\\"ir src" },
        .{ "src/main.zig", "const m = @import(\"<|>\");", "std builtin root bs\\\\mod.zig nl\\nx.zig" },
        .{ "src/main.zig", "const m = @import(\"../d\\\"ir/<|>\");", "../d\\\"ir/inner.zig" },
        .{ "src/main.zig", "const m = @import(\"../src/<|>\");", "../src/bs\\\\mod.zig ../src/nl\\nx.zig" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const at = try w.addNative(try std.fs.path.join(w.arena.allocator(), &.{ dir, c[0] }), c[1]);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const items = (try completion.complete(&r, at.file, at.cursor, .{ .auto_import = false })).items;
        var labels: std.ArrayList([]const u8) = .empty;
        for (items) |it| try labels.append(w.arena.allocator(), it.label);
        // Paths in the order of the directory listing
        const modules: usize = if (std.mem.startsWith(u8, c[2], "std")) 3 else 0;
        std.mem.sort([]const u8, labels.items[modules..], {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        testing.expectEqualStrings(c[2], try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
            std.debug.print("{s}: `{s}`\n", .{ c[0], c[1] });
            return err;
        };
    }
}

test "build.zig.zon paths go to the files they name" {
    var root: ManifestRoot = try .create();
    defer root.deinit();
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\.{
        \\    .version = "build.zig",
        \\    .dependencies = .{
        \\        .foo = .{ .path = "libs/foo" },
        \\        .bar = .{ .path = "build.zig" },
        \\    },
        \\    .paths = .{ "build.zig", "src/main.zig", "README.md", "src", "", "missing.zig", "/build.zig" },
        \\}
        \\
    ;
    const file = (try root.add(&w, text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "\"build.zig\", \"src", "build.zig" },
        .{ "src/main.zig", "src/main.zig" },
        .{ "README.md", "README.md" },
        // The `.path` of a dependency goes to a file as well
        .{ "build.zig\" }", "build.zig" },
        // Directories, missing files, absolute paths, and strings that are not paths
        .{ "\"src\"", null },
        .{ "\"\"", null },
        .{ "missing.zig", null },
        .{ "/build.zig", null },
        .{ "libs/foo", null },
        .{ "build.zig\",\n", null },
    };
    for (cases) |c| {
        const offset: u32 = @intCast(std.mem.indexOf(u8, text, c[0]).? + 1);
        const got = try definition.manifestPath(&r, file, offset);
        if (c[1]) |want| {
            const path = got orelse {
                std.debug.print("no path at `{s}`\n", .{c[0]});
                return error.NoDefinition;
            };
            // Normalized: the path in `want` uses `/`, while paths on Windows use `\`
            const joined = try std.fs.path.join(w.arena.allocator(), &.{ root.dir, want });
            const expected = switch (w.vfs.style) {
                inline else => |style| try Vfs.normalize(style, w.arena.allocator(), joined),
            };
            try testing.expectEqualStrings(expected.?, path);
        } else testing.expectEqual(null, got) catch |err| {
            std.debug.print("path at `{s}`: {s}\n", .{ c[0], got.? });
            return err;
        };
    }
    // The target is not interned: interned files other than Zig sources are watched, and their
    // changes rebuild the project
    try testing.expectEqual(null, try w.vfs.lookup(try std.fs.path.join(w.arena.allocator(), &.{ root.dir, "README.md" })));
}

test "hover in generic bodies does not seed an array length no instance determines" {
    const text =
        \\extern fn external(n: usize) usize;
        \\fn measure(comptime fmt: []const u8) usize { return external(fmt.len); }
        \\fn print(comptime fmt: []const u8) *const [measure(fmt):0]u8 { return undefined; }
        \\fn gen(comptime T: type) void {
        \\    const s = print("{d}");
        \\    const t: T = undefined;
        \\    _ = .{ s, t };
        \\}
        \\test {
        \\    gen(u8);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        // The length depends on no parameter of `gen`: the same in every instance
        .{ "s =", "```zig\nconst s: *const [_:0]u8\n```" },
        .{ "t: T", "```zig\nconst t: u8 = undefined\n```\n\ninferred from the call at main.zig:10" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "hover in generic bodies is inferred from a call site" {
    const text =
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        pub fn first(self: @This()) T { const it = self.items[0]; return it; }
        \\    };
        \\}
        \\fn max(comptime T: type, a: T, b: T) T {
        \\    const bigger = if (a > b) a else b;
        \\    return bigger;
        \\}
        \\fn run() void {
        \\    const l: List(u16) = undefined;
        \\    _ = l.first();
        \\    _ = max(u32, 1, 2);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "it =", "```zig\nconst it: u16\n```\n\ninferred from the call at main.zig:12" },
        .{ "bigger =", "```zig\nconst bigger: u32\n```\n\ninferred from the call at main.zig:14" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "hover on @This() in generic bodies is inferred from a call site like the written instance" {
    // `@This()` was the bare function name and counted as concrete, so it was never seeded
    const text =
        \\fn Pair(comptime A: type, comptime B: type) type {
        \\    return struct {
        \\        a: A,
        \\        b: B,
        \\        const Self = @This();
        \\        fn swap(p: @This(), s: Self) void {
        \\            const me = p;
        \\            const q: Pair(A, B) = p;
        \\            _ = .{ me, q, s };
        \\        }
        \\    };
        \\}
        \\test {
        \\    const x: Pair(u8, u16) = .{ .a = 1, .b = 2 };
        \\    x.swap(x);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    // The instance is that of the type constructor call `Pair(u8, u16)`
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "p: @This()", "```zig\np: Pair(u8, u16)\n```\n\ninferred from the call at main.zig:14" },
        .{ "s: Self", "```zig\ns: Pair(u8, u16)\n```\n\ninferred from the call at main.zig:14" },
        .{ "me =", "```zig\nconst me: Pair(u8, u16)\n```\n\ninferred from the call at main.zig:14" },
        .{ "q:", "```zig\nconst q: Pair(u8, u16)\n```\n\ninferred from the call at main.zig:14" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "goto declaration through comptime anytype parameters" {
    // Instances of `comptime H: anytype` record the argument value: members of type arguments can
    // be resolved (previously only the argument's type, `type`, was recorded)
    const text =
        \\const Md = struct {
        \\    pub const digest_length = 16;
        \\    pub fn hash(out: *[digest_length]u8) void {
        \\        _ = out;
        \\    }
        \\};
        \\fn check(comptime H: anytype, comptime hex: *const [H.digest_length * 2]u8) void {
        \\    var h: [H.digest_length]u8 = undefined;
        \\    H.hash(&h);
        \\    _ = hex;
        \\}
        \\test {
        \\    check(Md, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        // Parameter types in the signature
        .{ "digest_length * 2", "digest_length = 16" },
        .{ "digest_length]u8 = undefined", "digest_length = 16" },
        .{ "hash(&h)", "hash(out" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        try testing.expect(std.mem.startsWith(u8, text[t.start..], c[1]));
    }
}

test "goto declaration in format methods called only by std.Io.Writer.printValue" {
    // `format(self, writer: anytype)` is called only by `{f}` through printValue's
    // `value.format(w)`: writer is `*std.Io.Writer`
    const text =
        \\const Fig = struct {
        \\    rows: u8,
        \\    pub fn format(self: Fig, writer: anytype) !void {
        \\        _ = self;
        \\        try writer.writeAll("x");
        \\    }
        \\};
        \\
    ;
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root_path = try std.fs.path.join(w.arena.allocator(), &.{ env.std_dir, "std.zig" });
    const std_root = try w.vfs.intern(std_root_path);
    const file = (try w.add("/p/main.zig", text)).file;
    try w.setGraph(std_root, &.{}, &.{});
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const t = try definition.declaration(&r, file, @intCast(std.mem.indexOf(u8, text, "writeAll").?)) orelse return error.NoTarget;
    try testing.expect(std.mem.endsWith(u8, w.vfs.path(t.file), "Writer.zig"));
}

test "hover in generic functions passed as a value with an argument tuple" {
    // `Thread.spawn(.{}, f, .{ a, b })`, `@call(.auto, f, .{ a })`: called with the tuple elements
    const text =
        \\fn spawn(f: anytype, args: anytype) void {
        \\    _ = .{ f, args };
        \\}
        \\const Ctx = struct { id: u8 };
        \\fn run() void {
        \\    spawn(worker, .{ Ctx{ .id = 1 }, 2 });
        \\    @call(.auto, other, .{@as(u16, 3)});
        \\}
        \\fn worker(ctx: anytype, n: u32) void {
        \\    const got = ctx;
        \\    _ = .{ got, n };
        \\}
        \\fn other(x: anytype) void {
        \\    const y = x;
        \\    _ = y;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "got =", "```zig\nconst got: Ctx\n```\n\ninferred from the call at main.zig:6" },
        .{ "y =", "```zig\nconst y: u16\n```\n\ninferred from the call at main.zig:7" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "hover in generic bodies called only from other generic functions" {
    const text =
        \\const Px = struct { r: u8 };
        \\fn over(dst: anytype, src: anytype) @TypeOf(dst, src) {
        \\    const v = src;
        \\    return v;
        \\}
        \\fn run(op: u8, dst: anytype, src: anytype) @TypeOf(dst, src) {
        \\    return switch (op) {
        \\        else => over(dst, src),
        \\    };
        \\}
        \\fn paint() void {
        \\    const p: Px = .{ .r = 0 };
        \\    _ = run(0, p, p);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    // `over` is called only in the generic `run`: the concrete type comes through the call-site
    // instance of `run`
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "v =").?), &.{}, .list) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst v: Px\n```\n\ninferred from the call at main.zig:8", info.text);
}

test "hover in generic bodies through two levels of generic callers" {
    const text =
        \\const Px = struct { r: u8 };
        \\fn leaf(src: anytype) @TypeOf(src) {
        \\    const v = src;
        \\    return v;
        \\}
        \\fn mid(src: anytype) @TypeOf(src) {
        \\    return leaf(src);
        \\}
        \\fn run(op: u8, src: anytype) @TypeOf(src) {
        \\    return switch (op) {
        \\        else => mid(src),
        \\    };
        \\}
        \\fn paint() void {
        \\    const p: Px = .{ .r = 0 };
        \\    _ = run(0, p);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    // `leaf` <- generic `mid` <- generic `run` <- concrete call
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "v =").?), &.{}, .list) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst v: Px\n```\n\ninferred from the call at main.zig:7", info.text);
}

test "hover in generic bodies is inferred from a call site in another file" {
    const lib_text =
        \\pub fn max(comptime T: type, a: T, b: T) T {
        \\    const bigger = if (a > b) a else b;
        \\    return bigger;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const lib = (try w.add("/p/lib.zig", lib_text)).file;
    // Files that do not import lib.zig do not take part, even if they have calls of the same name
    const other = (try w.add("/p/a.zig", "fn max(comptime T: type, a: T, b: T) T { return a; }\nfn f() void { _ = max(u8, 1, 2); }\n")).file;
    const main = (try w.add("/p/main.zig", "const lib = @import(\"lib.zig\");\nfn run() void {\n    _ = lib.max(i64, 1, 2);\n}\n")).file;
    try w.setGraph(null, &.{.{ .root = main, .imports = &.{} }}, &.{
        .{ .file = other, .module = 0, .compile = 0 },
        .{ .file = main, .module = 0, .compile = 0 },
        .{ .file = lib, .module = 0, .compile = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = try hover.hover(&r, lib, @intCast(std.mem.indexOf(u8, lib_text, "bigger =").?), &.{}, .list) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst bigger: i64\n```\n\ninferred from the call at main.zig:3", info.text);
}

test "hover in generic bodies takes the same call site whatever order the files were interned in" {
    // The first call site followed the interning order of the files, so the instance depended on
    // the order in which the client opened them
    const util_text =
        \\pub fn first(comptime T: type, items: []const T) T {
        \\    const head = items[0];
        \\    return head;
        \\}
        \\
    ;
    const main_text = "const util = @import(\"util.zig\");\nconst Point = struct { x: u8 };\nfn run() void {\n    _ = util.first(Point, &.{});\n}\n";
    const net_text = "const util = @import(\"util.zig\");\nconst Color = enum { red };\nfn run() void {\n    _ = util.first(Color, &.{});\n}\n";
    var results: [2][]const u8 = undefined;
    for (&results, [_]bool{ false, true }) |*out, net_first| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const util = (try w.add("/p/util.zig", util_text)).file;
        var main: FileId = undefined;
        var net: FileId = undefined;
        if (net_first) {
            net = (try w.add("/p/net.zig", net_text)).file;
            main = (try w.add("/p/main.zig", main_text)).file;
        } else {
            main = (try w.add("/p/main.zig", main_text)).file;
            net = (try w.add("/p/net.zig", net_text)).file;
        }
        try w.setGraph(null, &.{.{ .root = main, .imports = &.{} }}, &.{
            .{ .file = main, .module = 0, .compile = 0 },
            .{ .file = net, .module = 0, .compile = 0 },
            .{ .file = util, .module = 0, .compile = 0 },
        });
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const info = try hover.hover(&r, util, @intCast(std.mem.indexOf(u8, util_text, "head =").?), &.{}, .list) orelse return error.NoHover;
        out.* = try testing.allocator.dupe(u8, info.text);
    }
    defer for (results) |t| testing.allocator.free(t);
    // Call sites at the same import distance are taken in path order
    try testing.expectEqualStrings("```zig\nconst head: Point\n```\n\ninferred from the call at main.zig:4", results[0]);
    try testing.expectEqualStrings(results[0], results[1]);
}

test "hover in generic bodies: call sites through aliases" {
    const lib_text =
        \\pub fn max(comptime T: type, a: T, b: T) T {
        \\    const bigger = if (a > b) a else b;
        \\    return bigger;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const lib = (try w.add("/p/lib.zig", lib_text)).file;
    // Alias of an alias: only `top` appears in main.zig, not `max`
    const alias = (try w.add("/p/alias.zig", "const lib = @import(\"lib.zig\");\npub const biggest = lib.max;\npub const top = biggest;\n")).file;
    const main = (try w.add("/p/main.zig", "const alias = @import(\"alias.zig\");\nfn run() void {\n    _ = alias.top(u16, 1, 2);\n}\n")).file;
    try w.setGraph(null, &.{.{ .root = main, .imports = &.{} }}, &.{
        .{ .file = alias, .module = 0, .compile = 0 },
        .{ .file = main, .module = 0, .compile = 0 },
        .{ .file = lib, .module = 0, .compile = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = try hover.hover(&r, lib, @intCast(std.mem.indexOf(u8, lib_text, "bigger =").?), &.{}, .list) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst bigger: u16\n```\n\ninferred from the call at main.zig:3", info.text);
}

test "completion after `.` lists members of the expected type" {
    const decls =
        \\const E = enum {
        \\    red,
        \\    green,
        \\    pub const default: E = .red;
        \\    pub fn parse(s: []const u8) E {
        \\        _ = s;
        \\        return .red;
        \\    }
        \\    fn count() u8 {
        \\        return 2;
        \\    }
        \\};
        \\const U = union(enum) { num: u8, none };
        \\const V = union {
        \\    a: u8,
        \\    pub const k = 1;
        \\};
        \\const S = struct {
        \\    x: u8,
        \\    pub const empty: S = .{ .x = 0 };
        \\    pub fn init() !S {
        \\        return .empty;
        \\    }
        \\    pub fn size() usize {
        \\        return 1;
        \\    }
        \\};
        \\fn take(e: E) void {
        \\    _ = e;
        \\}
        \\
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "const c: E = .<|>;", "red green default parse" },
        .{ "fn f() void { take(.gr<|>); }", "red green default parse" },
        .{ "fn f(e: E) void { switch (e) { .<|> => {}, else => {} } }", "red green default parse" },
        .{ "const c: ?E = .<|>;", "red green default parse" },
        // `init` returns `!S`, which does not coerce to `S`
        .{ "const s: S = .<|>;", "empty" },
        // Only the tag of a field with one possible value coerces to the union
        .{ "const u: U = .<|>;", "none" },
        // The result type drops the error union and optional
        .{ "fn f() !E { return .<|>; }", "red green default parse" },
        .{ "fn f() error{X}!?U { return .<|>; }", "none" },
        // For a tagged union, accessing fields on the type gives the tags; untagged unions have
        // none
        .{ "const t = U.<|>;", "num none" },
        .{ "const t = V.<|>;", "k" },
        // No expected type
        .{ "const c = .<|>;", "" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.mem.concat(w.arena.allocator(), u8, &.{ decls, c[0], "\n" });
        const added = try w.add("/p/main.zig", text);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
        var labels: std.ArrayList([]const u8) = .empty;
        for (items) |it| try labels.append(w.arena.allocator(), it.label);
        testing.expectEqualStrings(c[1], try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }
}

/// Completes at `<|>` in `decls` followed by each case and expects the labels joined by spaces
fn expectCompletions(decls: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.mem.concat(w.arena.allocator(), u8, &.{ decls, c[0], "\n" });
        testing.expectEqualStrings(c[1], try completionAt(&w, try w.add("/p/main.zig", text))) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }
}

test "completion: enum literals at unnamed elements of array, slice and tuple initializers" {
    const decls =
        \\const Color = enum { red, green, blue };
        \\const Cfg = struct { colors: []const Color = &.{}, one: Color = .red };
        \\fn takeColors(cs: []const Color) usize {
        \\    return cs.len;
        \\}
        \\
    ;
    try expectCompletions(decls, &.{
        .{ "const a = [_]Color{ .red, .<|> };", "red green blue" },
        .{ "const a = [_]Color{ .<|> };", "red green blue" },
        .{ "const a = [_]Color{ .gr<|> };", "red green blue" },
        .{ "const b: [2]Color = .{ .red, .<|> };", "red green blue" },
        .{ "fn f() void {\n    _ = takeColors(&.{ .green, .<|> });\n}", "red green blue" },
        .{ "const d: struct { Color, u8 } = .{ .<|>, 1 };", "red green blue" },
        // A struct initializer lists the fields not yet assigned
        .{ "const g: Cfg = .{ .one = .red, .<|> };", "colors" },
    });
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.fixture("//- /p/main.zig module:app\n" ++ decls ++ "const Pair = struct { pair: [2]Color = .{ .red, .red } };\nconst cfg: Cfg = @import(\"cfg.zon\");\nconst pair: Pair = @import(\"pair.zon\");");
    try testing.expectEqualStrings("red green blue", try completionAt(&w, try w.add("/p/cfg.zon", ".{ .colors = .{ .red, .<|> } }")));
    try testing.expectEqualStrings("red green blue", try completionAt(&w, try w.add("/p/pair.zon", ".{ .pair = .{ .<|>, .blue } }")));
}

test "completion after `try .` lists the functions returning an error union of the result type" {
    try expectCompletions(
        \\const S = struct {
        \\    pub const empty: S = .{};
        \\    pub fn tryMake() !S {
        \\        return .{};
        \\    }
        \\    pub fn make() S {
        \\        return .{};
        \\    }
        \\};
        \\
    , &.{
        .{ "fn f() !void {\n    const s: S = try .<|>;\n    _ = s;\n}", "tryMake" },
        .{ "fn f() !void {\n    const s: S = try .tryM<|>;\n    _ = s;\n}", "tryMake" },
        .{ "fn f() !void {\n    const s: S = try .<|>\n}", "tryMake" },
        .{ "fn mk() !S {\n    return try .<|>;\n}", "tryMake" },
        .{ "fn mk() !S {\n    return try .<|>\n}", "tryMake" },
        // `try .make()` is a compile error: `make` returns no error union
        .{ "fn f() !void {\n    const s: S = try .tryM<|>();\n    _ = s;\n}", "tryMake" },
    });

    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try useRealStd(&w);
    const labels = try completionAt(&w, try w.add("/p/main.zig",
        \\const std = @import("std");
        \\fn f() !void {
        \\    var list: std.ArrayList(u8) = try .<|>;
        \\    _ = &list;
        \\}
        \\
    ));
    try testing.expectEqualStrings("initCapacity clone", labels);
}

test "completion of reified union tags and of @Struct and @Union initializer fields" {
    try expectCompletions(
        \\const E = @Enum(u8, .exhaustive, &.{ "ra", "rb" }, &.{ 0, 1 });
        \\const T = @Struct(.auto, null, &.{ "fa", "fb" }, &.{ u32, bool }, &.{ .{}, .{} });
        \\const U = @Union(.auto, E, &.{ "ra", "rb" }, &.{ u32, void }, &.{ .{}, .{} });
        \\const UU = @Union(.auto, null, &.{ "ua", "ub" }, &.{ u32, void }, &.{ .{}, .{} });
        \\
    , &.{
        .{ "const x = U.<|>;", "ra rb" },
        .{ "const t: T = .{ .<|> };", "fa fb" },
        .{ "const t: T = .{ .fa = 1, .<|> };", "fb" },
        .{ "const u: U = .{ .<|> };", "ra rb" },
        // Only the tag of a field with one possible value coerces to the union
        .{ "const u: U = .<|>;", "rb" },
        // An untagged union has no tags
        .{ "const x = UU.<|>;", "" },
        .{ "const u: UU = .<|>;", "" },
        .{ "const u: UU = .{ .<|> };", "ua ub" },
    });

    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try useRealStd(&w);
    const labels = try completionAt(&w, try w.add("/p/main.zig",
        \\const std = @import("std");
        \\const Dir = enum { north, south };
        \\const a = std.EnumArray(Dir, u32).init(.{ .<|> });
        \\
    ));
    try testing.expectEqualStrings("north south", labels);
}

/// The completion items at the cursor of `text` (a `.zig` file) as `label@start-end:filter`
/// joined by spaces, with the replace range relative to the cursor
fn completionEdits(text: []const u8) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const at = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for ((try completion.complete(&r, at.file, at.cursor, .{ .auto_import = false })).items) |it| {
        if (out.items.len != 0) try out.append(testing.allocator, ' ');
        try out.print(testing.allocator, "{s}", .{it.label});
        if (it.replace) |range| try out.print(testing.allocator, "@{d}-{d}", .{ @as(i64, range.start) - at.cursor, @as(i64, range.end) - at.cursor });
        if (it.filter) |f| try out.print(testing.allocator, ":{s}", .{f});
    }
    return out.toOwnedSlice(testing.allocator);
}

test "completion inside a quoted identifier offers the candidates of a plain prefix" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "fn f() void {\n    const @\"my var\": u32 = 1;\n    _ = @\"my v<|>\";\n}\n", "@\"my var\"@-6-1:@\"my var\" f@-6-1:@\"f\"" },
        // Unterminated: the text after the cursor is kept
        .{ "fn f() void {\n    const @\"my var\": u32 = 1;\n    _ = @\"my v<|>\n}\n", "@\"my var\"@-6-0:@\"my var\" f@-6-0:@\"f\"" },
        .{ "fn f(@\"align\": u32) u32 {\n    return @\"al<|>\";\n}\n", "@\"align\"@-4-1:@\"align\" f@-4-1:@\"f\"" },
        .{ "const S = struct { @\"error\": u8 = 0, other: u8 = 0 };\nfn f(s: S) void {\n    _ = s.@\"er<|>\";\n}\n", "@\"error\"@-4-1:@\"error\" other@-4-1:@\"other\"" },
        .{ "const S = struct { @\"error\": u8 = 0, other: u8 = 0 };\nfn f(s: S) void {\n    _ = s.@\"er<|>\n}\n", "@\"error\"@-4-0:@\"error\" other@-4-0:@\"other\"" },
        .{ "const K = enum { @\"struct\", @\"enum\" };\nfn f(k: K) void {\n    switch (k) {\n        .@\"st<|>\" => {},\n        else => {},\n    }\n}\n", "@\"struct\"@-4-1:@\"struct\" @\"enum\"@-4-1:@\"enum\"" },
        // No builtins in a name, and no candidates for a declaration name
        .{ "fn f() void {\n    _ = @\"@si<|>zeOf\";\n}\n", "f@-5-5:@\"f\"" },
        .{ "fn f() void {\n    const @\"my v<|>\" = 1;\n}\n", "" },
    };
    for (cases, 0..) |c, i| {
        const got = try completionEdits(c[0]);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }
}

test "completion on the name of an existing initializer field lists the fields" {
    try expectCompletions(
        \\const S = struct { alpha: u32 = 0, beta: u32 = 0 };
        \\
    , &.{
        .{ "fn f() void {\n    const local = 5;\n    const s1: S = .{ .al<|> = 1 };\n    _ = .{ s1, local };\n}", "alpha beta" },
        .{ "fn f() void {\n    const local = 5;\n    const s1 = S{ .be<|> = 2 };\n    _ = .{ s1, local };\n}", "alpha beta" },
        .{ "fn f() void {\n    const local = 5;\n    const s1: S = .{ .a<|>lpha = 1 };\n    _ = .{ s1, local };\n}", "alpha beta" },
        .{ "fn f() void {\n    const local = 5;\n    const s1: S = .{ .alpha = 1, .b<|> = 2 };\n    _ = .{ s1, local };\n}", "beta" },
    });
}

test "decl literal completion keeps the declarations that coerce to the result type" {
    try expectCompletions(
        \\const S = struct {
        \\    a: u32 = 0,
        \\    pub const init: S = .{};
        \\    pub const default_ptr: *const S = &init;
        \\    pub fn tryMake() !S {
        \\        return .{};
        \\    }
        \\    pub fn make() S {
        \\        return .{};
        \\    }
        \\    pub fn ptrMake() *const S {
        \\        return &init;
        \\    }
        \\    pub fn failA() error{A}!S {
        \\        return error.A;
        \\    }
        \\    pub fn failC() error{C}!S {
        \\        return error.C;
        \\    }
        \\};
        \\const Color = enum {
        \\    red,
        \\    green,
        \\    pub fn maybe(i: u8) ?Color {
        \\        return if (i == 0) null else .red;
        \\    }
        \\    pub const none_c: ?Color = null;
        \\};
        \\const E = error{ A, B };
        \\fn takeSP(s: *const S) void {
        \\    _ = s;
        \\}
        \\
    , &.{
        .{ "const s: S = .<|>;", "init make" },
        .{ "const c: ?Color = .<|>;", "red green maybe none_c" },
        // A tag does not coerce to a pointer
        .{ "const c: *const Color = .<|>;", "" },
        .{ "fn f() void {\n    takeSP(.<|>);\n}", "default_ptr ptrMake" },
        .{ "fn f() !S {\n    return .<|>;\n}", "init tryMake make failA failC" },
        // The error set of the result type must contain the errors of an explicit set; an inferred
        // error set is not known before the function body is analyzed
        .{ "fn f() E!S {\n    return .<|>;\n}", "init tryMake make failA" },
    });
}

test "completion after `.` with a union result type lists only the tags that coerce to it" {
    try expectCompletions(
        \\const U = union(enum) {
        \\    int: u32,
        \\    none,
        \\    unit: struct {},
        \\    pub const zero: U = .{ .int = 0 };
        \\};
        \\const UU = union {
        \\    a: u32,
        \\    b: void,
        \\    pub const first: UU = .{ .a = 1 };
        \\};
        \\const R = @Union(.auto, enum { ra, rb }, &.{ "ra", "rb" }, &.{ u32, void }, &.{ .{}, .{} });
        \\
    , &.{
        .{ "const u: U = .<|>;", "none unit zero" },
        .{ "const uu: UU = .<|>;", "first" },
        // Switch prongs and comparisons take the tag type
        .{ "fn f(u: U) void {\n    switch (u) {\n        .<|> => {},\n        else => {},\n    }\n}", "int none unit" },
        .{ "fn f(u: U) bool {\n    return u == .<|>;\n}", "int none unit" },
        .{ "fn f(u: R) void {\n    switch (u) {\n        .<|> => {},\n        else => {},\n    }\n}", "ra rb" },
    });
}

test "completion and inference of `ptr` on pointers to arrays" {
    try expectCompletions("", &.{
        .{ "fn f() void {\n    var arr = [_]u8{ 1, 2, 3 };\n    const pa: *[3]u8 = &arr;\n    _ = pa.<|>;\n}", "len ptr" },
        .{ "fn f() void {\n    _ = \"abc\".<|>;\n}", "len ptr" },
        .{ "fn f() void {\n    var arr = [_]u8{ 1, 2, 3 };\n    _ = arr[0..2].<|>;\n}", "len ptr" },
        // An array value has no `ptr`
        .{ "fn f() void {\n    var arr = [_]u8{ 1, 2, 3 };\n    _ = &arr;\n    _ = arr.<|>;\n}", "len" },
    });
    const text =
        \\fn f() void {
        \\    var arr = [_]u8{ 1, 2, 3 };
        \\    const pa: *[3]u8 = &arr;
        \\    const x = pa.ptr;
        \\    const y = "abc".ptr;
        \\    _ = .{ x, y };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try testing.expectEqualStrings(
        \\fn f() void {
        \\    var arr: [3]u8 = [_]u8{ 1, 2, 3 };
        \\    const pa: *[3]u8 = &arr;
        \\    const x: [*]u8 = pa.ptr;
        \\    const y: [*:0]const u8 = "abc".ptr;
        \\    _ = .{ x, y };
        \\}
        \\
    , try inlaid(&w, file, text, .{ .parameters = false }));
}

test "label completion after `continue :` lists only loop and switch labels" {
    try expectCompletions("", &.{
        .{ "fn f() void {\n    lp: while (true) {\n        blk: {\n            if (true) continue :<|>;\n            break :blk;\n        }\n    }\n}", "lp" },
        .{ "fn f() void {\n    lp: while (true) {\n        blk: {\n            if (true) continue :lp;\n            break :<|>;\n        }\n    }\n}", "blk lp" },
        .{ "fn f() void {\n    blk: {\n        while (true) {\n            continue :<|>;\n        }\n    }\n}", "" },
        .{ "fn f(x: u8) void {\n    sw: switch (x) {\n        0 => {\n            continue :<|> 1;\n        },\n        else => {},\n    }\n}", "sw" },
    });
}

test "name completion inside a struct declared in a function lists only the values it can access" {
    try expectCompletions("", &.{
        .{
            \\fn outer(n: u32, comptime k: u32) u32 {
            \\    var counter: u32 = 0;
            \\    _ = &counter;
            \\    const limit: u32 = 10;
            \\    const sum = n + 1;
            \\    const Ctx = struct {
            \\        fn get() u32 {
            \\            return <|>;
            \\        }
            \\    };
            \\    _ = .{ sum, limit };
            \\    return Ctx.get();
            \\}
            ,
            "get limit k outer",
        },
        // Runtime values are accessible inside `@TypeOf`
        .{
            \\fn outer(n: u32) u32 {
            \\    var counter: u32 = 0;
            \\    _ = &counter;
            \\    const Ctx = struct {
            \\        fn get() u32 {
            \\            return @sizeOf(@TypeOf(<|>));
            \\        }
            \\    };
            \\    return Ctx.get();
            \\}
            ,
            "get counter n outer",
        },
        // The calls of a function returning `type` are evaluated at comptime: only `var`s are not
        // accessible
        .{
            \\fn Outer(n: u32) type {
            \\    var counter: u32 = 0;
            \\    _ = &counter;
            \\    const sum = n + 1;
            \\    return struct {
            \\        fn get() u32 {
            \\            return <|>;
            \\        }
            \\    };
            \\}
            ,
            "get sum n Outer",
        },
    });
}

/// Whether the completion at the cursor is incomplete
fn incompleteAt(w: *World, at: World.Added, options: completion.Options) !bool {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    return (try completion.complete(&r, at.file, at.cursor, options)).is_incomplete;
}

test "empty-prefix name completion is incomplete when a typed prefix adds candidates" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const at = try w.add("/p/main.zig",
        \\const Holder = struct { gpa_field: u32 = 0 };
        \\fn f(h: Holder) void {
        \\    _ = <|>;
        \\}
        \\
    );
    // Member paths of local values (`h.gpa_field`) are added once a prefix is typed
    try testing.expect(try incompleteAt(&w, at, .{ .auto_import = false }));
    // So are auto-import candidates
    try testing.expect(try incompleteAt(&w, at, .{}));
    try testing.expect(try incompleteAt(&w, at, .{ .snippets = true }));
    // Member completion is complete
    const member = try w.add("/p/main.zig",
        \\const Holder = struct { gpa_field: u32 = 0 };
        \\fn f(h: Holder) void {
        \\    _ = h.<|>;
        \\}
        \\
    );
    try testing.expect(!try incompleteAt(&w, member, .{}));
}

test "empty-prefix completion at a parameter or return type offers the earlier parameters" {
    try expectCompletions("", &.{
        .{ "fn sig2(comptime Tee: type, second: <|>) void {}", "Tee sig2" },
        .{ "fn sig2(comptime Tee: type, second: []const <|>) void {}", "Tee sig2" },
        .{ "fn sig2(comptime Tee: type, second: ?<|>) void {}", "Tee sig2" },
        .{ "fn sig3(comptime Tee: type) <|> {}", "Tee sig3" },
        .{ "fn sig3(comptime Tee: type) !<|> {}", "Tee sig3" },
        .{ "const S = struct {\n    fn m(comptime Tee: type, x: *<|>) void {}\n};", "Tee m S" },
        // Without a body yet; inner names first
        .{ "const other = 1;\n\nfn foo(comptime Tee: type, x: Tee) <|>\n\npub fn main() void {}", "x Tee other foo main" },
    });
}

test "branches excluded by comptime conditions are inactive" {
    const text =
        \\const debug = false;
        \\fn f(x: u32) u32 {
        \\    if (debug) {
        \\        return x + 1;
        \\    }
        \\    const y = switch (@sizeOf(u16)) {
        \\        2 => x,
        \\        else => x * 2,
        \\    };
        \\    if (x > 3) return y;
        \\    return y;
        \\}
        \\fn g(comptime T: type, x: T) T {
        \\    if (T == u8) return x;
        \\    return x;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const ranges = try inactive.ranges(&r, file);
    // Runtime conditions and conditions that depend on abstract parameters are not inactive code
    try testing.expectEqual(2, ranges.len);
    try testing.expectEqualStrings("{\n        return x + 1;\n    }", text[ranges[0].start..ranges[0].end]);
    try testing.expectEqualStrings("x * 2", text[ranges[1].start..ranges[1].end]);
}

test "switch prongs on a comptime-known tagged union are inactive unless they match" {
    // When the operand is a tagged union, the executed prong used to be unknown, and none of the
    // other prongs were judged inactive
    const text =
        \\const U = union(enum) { x: u32, y: void };
        \\const u: U = .{ .x = 1 };
        \\fn f() u32 {
        \\    switch (u) {
        \\        .x => |v| return v,
        \\        .y => return 0,
        \\    }
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const ranges = try inactive.ranges(&r, file);
    try testing.expectEqual(1, ranges.len);
    try testing.expectEqualStrings("return 0", text[ranges[0].start..ranges[0].end]);
}

test "switch prongs on a comptime-known integer are inactive unless a range item contains it" {
    // A range item has no single value, so no prong was chosen and none was judged inactive
    const text =
        \\const n: u8 = 42;
        \\fn f() u8 {
        \\    return switch (n) {
        \\        0...9 => 1,
        \\        10...99 => 2,
        \\        else => 3,
        \\    };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const ranges = try inactive.ranges(&r, file);
    try testing.expectEqual(2, ranges.len);
    try testing.expectEqualStrings("1", text[ranges[0].start..ranges[0].end]);
    try testing.expectEqualStrings("3", text[ranges[1].start..ranges[1].end]);
}

/// Uses the real standard library of the local zig (skipped when PATH has no zig): `@typeInfo`
/// needs `std.builtin.Type`
fn useRealStd(w: *World) !void {
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    const std_root_path = try std.fs.path.join(testing.allocator, &.{ env.std_dir, "std.zig" });
    defer testing.allocator.free(std_root_path);
    try w.setGraph(try w.vfs.intern(std_root_path), &.{}, &.{});
}

test "switch prongs on @typeInfo of a concrete type are inactive unless they match" {
    const text =
        \\fn g() u16 {
        \\    return switch (@typeInfo(u16)) {
        \\        .int => |i| i.bits,
        \\        else => 7,
        \\    };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const ranges = try inactive.ranges(&r, file);
    try testing.expectEqual(1, ranges.len);
    try testing.expectEqualStrings("7", text[ranges[0].start..ranges[0].end]);
}

test "conditions on members of abstract parameters are not inactive" {
    // Prevents evaluating `@hasDecl` / `@hasField` to false when there is no instance: in generic
    // code with call sites, the branches actually executed would be shown as inactive
    const text =
        \\fn hasInner(comptime T: type) bool {
        \\    return @hasDecl(T, "Inner");
        \\}
        \\fn k(comptime T: type) u32 {
        \\    if (comptime @hasDecl(T, "Inner")) return 1;
        \\    if (comptime hasInner(T)) return 2;
        \\    if (comptime @hasField(T, "x")) return 3;
        \\    return 0;
        \\}
        \\fn Foo(comptime T: type) type {
        \\    return struct {
        \\        const has_inner = @hasDecl(T, "Inner");
        \\        fn m() u32 {
        \\            if (has_inner) return 1;
        \\            return 0;
        \\        }
        \\    };
        \\}
        \\const Arg = struct {
        \\    pub const Inner = u8;
        \\    x: u8,
        \\};
        \\fn caller() u32 {
        \\    return k(Arg) + Foo(Arg).m();
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const ranges = try inactive.ranges(&r, file);
    testing.expectEqual(0, ranges.len) catch |err| {
        for (ranges) |rg| std.debug.print("inactive: `{s}`\n", .{text[rg.start..rg.end]});
        return err;
    };
}

test "conditions on the root of a file outside every module are not inactive" {
    // Prevents guessing a root file (such as the file itself) for a file that belongs to no module:
    // it may be imported by another file through a relative path, or compiled by `zig test` (where
    // the root file is the test runner)
    const text =
        \\const root = @import("root");
        \\pub fn check() void {
        \\    if (@hasDecl(root, "main")) {
        \\        @panic("root has main");
        \\    }
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/helper.zig", text)).file;
    try w.setGraph(null, &.{}, &.{});
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    try testing.expectEqual(0, (try inactive.ranges(&r, file)).len);
}

test "completion, goto, signature help and inlay hints in generic bodies use a call site" {
    const text =
        \\const Point = struct {
        \\    x: i32,
        \\    pub fn scale(self: Point, k: i32) i32 { return self.x * k; }
        \\};
        \\fn twice(p: anytype) void {
        \\    const v = p.scale(2);
        \\    _ = v;
        \\    _ = p.x;
        \\}
        \\fn run() void {
        \\    twice(Point{ .x = 1 });
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = struct {
        fn f(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, text, needle).?);
        }
    }.f;

    // After `p.`: `p` is Point in the call-site instance
    const items = (try completion.complete(&r, file, at("p.x") + 2, .{ .auto_import = false })).items;
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    try testing.expectEqualStrings("x scale", try std.mem.join(w.arena.allocator(), " ", labels.items));

    const t = try definition.definition(&r, file, at("scale(2)")) orelse return error.NoDefinition;
    try testing.expect(std.mem.startsWith(u8, text[t.start..], "scale(self: Point"));

    const s = try signature_help.signatureHelp(&r, file, at("2);")) orelse return error.NoSignature;
    try testing.expectEqualStrings("fn scale(self: Point, k: i32) i32", s.label);
    try testing.expectEqual(1, s.active);

    // Unknown local variables in the abstract result: the type is taken from the call-site
    // instance, and the call it is based on is stated
    const hints = try inlay_hints.inlayHints(&r, file, at("const v"), at("_ = v"), .{});
    var found = false;
    for (hints) |h| if (h.kind == .type) {
        try testing.expectEqualStrings(": i32", h.label);
        try testing.expectEqualStrings("inferred from the call at main.zig:11", h.tooltip.?);
        found = true;
    };
    try testing.expect(found);
}

test "completion: builtins, labels, init fields and import names" {
    const decls =
        \\const S = struct { x: u8, y: u16, z: bool = false };
        \\
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        // Labels: inner first
        .{ "fn f() void { outer: while (true) { inner: { break :<|> } } }", "inner outer" },
        .{ "fn f() void { outer: while (true) { continue :ou<|>; } }", "outer" },
        // Fields not yet assigned in the initializer
        .{ "const s: S = .{ .x = 1, .<|> };", "y z" },
        .{ "const s = S{ .<|> };", "x y z" },
        .{ "const s: ?S = .{ .y = 2, .<|> };", "x z" },
        // Fields of a file, which is a struct
        .{ "w: u8,\nconst s: @This() = .{ .<|> };", "w" },
        // import: module names (only the fixed three without a project)
        .{ "const a = @import(\"<|>\");", "std builtin root" },
        // No completion in comments and strings (it used to list every name in scope)
        .{ "fn f() void {\n    const p: S = .{ .x = 1 };\n    // p.<|>\n    _ = p;\n}", "" },
        .{ "fn f() void {\n    _ = \"p.<|>\";\n}", "" },
        .{ "fn f() void {\n    _ = \"p.<|>\n}", "" },
        .{ "/// a @<|>\nconst T = 1;", "" },
        // Error names: members of the expected type's error set; without an expected type, the
        // error names that appear in this file
        .{ "const E = error{ Worse, Bad };\nfn f() E!void {\n    return error.<|>;\n}", "Bad Worse" },
        .{ "const E = error{ Worse, Bad };\nfn g() void {\n    const e = error.<|>;\n    _ = e;\n}\nfn h() !void {\n    return error.Other;\n}", "Worse Bad Other" },
        // An unfinished `error.` joins with the name on the next line (`error._`); that name is not
        // listed
        .{ "const E = error{ Worse, Bad };\nfn g() void {\n    const e = error.<|>\n    _ = e;\n}", "Worse Bad" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.mem.concat(w.arena.allocator(), u8, &.{ decls, c[0], "\n" });
        const added = try w.add("/p/main.zig", text);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
        var labels: std.ArrayList([]const u8) = .empty;
        for (items) |it| try labels.append(w.arena.allocator(), it.label);
        testing.expectEqualStrings(c[1], try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }

    // Builtin functions: the replacement range starts at `@` and ends at the end of the name
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", "fn f() void {\n    _ = @imp<|>ort;\n}\n");
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    try testing.expectEqual(std.zig.BuiltinFn.list.keys().len, items.len);
    const import = for (items) |it| {
        if (std.mem.eql(u8, it.label, "@import")) break it;
    } else return error.NoImport;
    try testing.expectEqual(added.cursor - 4, import.replace.?.start);
    try testing.expectEqual(added.cursor + 3, import.replace.?.end);
}

test "completion: no builtins after `.` or in zon files" {
    // The labels at the cursor; null for all builtins
    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        // Only a name follows `.`: `.@` starts a quoted member, initializer field, or enum member
        .{ "/p/main.zig", "const S = struct { @\"in\": u8, b: u8 };\nfn f(s: S) void { _ = s.@<|>; }", "@\"in\" @\"b\"" },
        .{ "/p/main.zig", "const S = struct { a: u8, b: u8 };\nconst s: S = .{ .@<|> };", "@\"a\" @\"b\"" },
        .{ "/p/main.zig", "const E = enum { a, b };\nfn f(e: E) void {\n    switch (e) {\n        .@<|> => {},\n        else => {},\n    }\n}", "@\"a\" @\"b\"" },
        .{ "/p/main.zig", "const S = struct { a: u8 };\nfn f(s: S) void { _ = s.@na<|>; }", "" },
        // ZON has no builtin calls
        .{ "/p/cfg.zon", ".{ .a = @<|> }", "" },
        // Expressions, including after `..`
        .{ "/p/main.zig", "const x = @<|>;", null },
        .{ "/p/main.zig", "fn f(n: u32) void {\n    for (0..@<|>) |_| {}\n}", null },
    };
    inline for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add(c[0], c[1]);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
        if (c[2]) |expected| {
            var labels: std.ArrayList([]const u8) = .empty;
            for (items) |it| {
                try labels.append(w.arena.allocator(), it.label);
                // The quoted name replaces the `@`
                try testing.expectEqual(added.cursor - 1, it.replace.?.start);
            }
            testing.expectEqualStrings(expected, try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
                std.debug.print("{s}: `{s}`\n", .{ c[0], c[1] });
                return err;
            };
        } else {
            try testing.expectEqual(std.zig.BuiltinFn.list.keys().len, items.len);
            for (items) |it| try testing.expectEqual(.builtin, it.kind);
        }
    }
}

test "goto and hover on error values: the expected error set picks the declaration" {
    // `error.Foo` used to have neither goto nor hover
    const lib_text =
        \\pub const LibError = error{ Missing, Busy };
        \\
    ;
    const text =
        \\const lib = @import("lib.zig");
        \\const Other = error{ Foo, Baz };
        \\const E = error{
        \\    /// the foo error
        \\    Foo,
        \\    Bar,
        \\};
        \\const M = Other || E;
        \\fn f() E!void {
        \\    return error.Foo;
        \\}
        \\fn g() void {
        \\    const x = error.Baz;
        \\    _ = x;
        \\}
        \\fn h() M!void {
        \\    return error.Bar;
        \\}
        \\fn k() lib.LibError!void {
        \\    return error.Missing;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const lib = (try w.add("/p/lib.zig", lib_text)).file;
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = struct {
        fn of(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, text, needle).?);
        }
    }.of;
    // Foo in the expected error set E, not the one in Other
    const foo = (try definition.definition(&r, file, at("Foo;") + 1)).?;
    try testing.expectEqual(file, foo.file);
    try testing.expectEqual(at("Foo,\n    Bar"), foo.start);
    // No expected type: the error set containing this name
    const baz = (try definition.definition(&r, file, at("Baz;") + 1)).?;
    try testing.expectEqual(at("Baz }"), baz.start);
    // Merged error set: the part of it that contains this name
    const bar = (try definition.definition(&r, file, at("Bar;") + 1)).?;
    try testing.expectEqual(at("Bar,\n};"), bar.start);
    // Error set declared in another file
    const missing = (try definition.definition(&r, file, at("Missing;") + 1)).?;
    try testing.expectEqual(lib, missing.file);
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, lib_text, "Missing").?)), missing.start);

    const info = (try hover.hover(&r, file, at("Foo;") + 1, &.{}, .list)).?;
    try testing.expectEqualStrings("```zig\nerror.Foo: error{Bar,Foo}\n```\n\nthe foo error", info.text);
    const plain = (try hover.hover(&r, file, at("Baz;") + 1, &.{}, .list)).?;
    try testing.expectEqualStrings("```zig\nerror.Baz\n```", plain.text);
}

test "goto and hover on quoted error names" {
    const text =
        \\const E = error{
        \\    /// quoted doc
        \\    @"Quoted",
        \\    /// escaped doc
        \\    @"\x45scaped",
        \\    /// spaced doc
        \\    @"a b",
        \\    Plain,
        \\};
        \\fn f() void {
        \\    _ = .{ error.Escaped, E.Quoted, E.Escaped, E.@"a b", error.@"\x45scaped" };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = struct {
        fn of(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, text, needle).?);
        }
    }.of;
    const cases = [_]struct { []const u8, u32, []const u8 }{
        // `error.X` is looked up by the decoded name
        .{ "error.Escaped", "error.".len, "@\"\\x45scaped\"" },
        .{ "error.@\"\\x45scaped\"", "error.".len, "@\"\\x45scaped\"" },
        // The token of `E.X` is quoted in the source, and the range covers the token itself
        .{ "E.Quoted", "E.".len, "@\"Quoted\"" },
        .{ "E.Escaped", "E.".len, "@\"\\x45scaped\"" },
        .{ "E.@\"a b\"", "E.".len, "@\"a b\"" },
    };
    for (cases) |c| {
        const t = (try definition.definition(&r, file, at(c[0]) + c[1])) orelse {
            std.debug.print("no target for `{s}`\n", .{c[0]});
            return error.NoTarget;
        };
        const decl_at = at(c[2]);
        try testing.expectEqual(decl_at, t.start);
        try testing.expectEqual(decl_at + @as(u32, @intCast(c[2].len)), t.end);
    }
    // hover includes the docs for the escaped name
    const info = (try hover.hover(&r, file, at("error.Escaped") + @as(u32, "error.".len), &.{}, .list)).?;
    try testing.expect(std.mem.endsWith(u8, info.text, "escaped doc"));
}

test "goto on an error value without an expected error set stops at the first declaration" {
    // Without an expected error set, all declarations match equally and the result is always the
    // first; it used to keep indexing every file in the import closure after finding it
    const text =
        \\const a = @import("a.zig");
        \\fn g() void {
        \\    const x = error.Baz;
        \\    _ = x;
        \\}
        \\
    ;
    const a_text =
        \\const b = @import("b.zig");
        \\pub const E = error{Baz};
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = (try w.add("/p/a.zig", a_text)).file;
    const b = (try w.add("/p/b.zig", "pub const F = error{ Baz, Qux };\n")).file;
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var trace: @import("../db/engine.zig").Trace = .{ .gpa = w.arena.allocator() };
    ctx.trace = &trace;
    var r = resolver(&w, &ctx);
    const baz = (try definition.definition(&r, file, @intCast(std.mem.indexOf(u8, text, "Baz").? + 1))).?;
    try testing.expectEqual(a, baz.file);
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, a_text, "Baz").?)), baz.start);
    const index_query = comptime for (database.Db.query_types, 0..) |Q, qi| {
        if (Q == database.FileIndex.Query) break qi;
    } else unreachable;
    for (trace.events.items) |ev| if (ev.query == index_query) {
        try testing.expect(w.db.keyAt(database.FileIndex.Query, ev.key) != b);
    };
}

test "goto declaration, definition through aliases and type definition" {
    const text =
        \\const Point = struct { x: i32 };
        \\const P = Point;
        \\fn make() ?*Point {
        \\    return null;
        \\}
        \\fn List(comptime T: type) type {
        \\    return struct { item: T };
        \\}
        \\fn f() void {
        \\    const p = make();
        \\    const q: P = undefined;
        \\    const l: List(u8) = undefined;
        \\    _ = .{ p, q, l };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const Fn = *const fn (*resolve.Resolver, @import("../base/Vfs.zig").FileId, u32) resolve.Error!?definition.Target;
    const cases = [_]struct { Fn, []const u8, []const u8 }{
        // definition follows the alias to Point; declaration stops at P
        .{ definition.definition, "P = undefined", "Point = struct" },
        .{ definition.declaration, "P = undefined", "P = Point" },
        // type definition: strips optional and pointers; type annotations through aliases; the type
        // name itself
        .{ definition.typeDefinition, "p = make", "Point = struct" },
        .{ definition.typeDefinition, "q: P", "Point = struct" },
        .{ definition.typeDefinition, "Point {", "Point = struct" },
        // Container returned by a generic function: goes to the container itself
        .{ definition.typeDefinition, "l: List", "struct { item" },
    };
    for (cases, 0..) |c, i| {
        const t = try c[0](&r, file, @intCast(std.mem.indexOf(u8, text, c[1]).?)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[2])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..@min(text.len, t.start + 20)] });
            return err;
        };
    }
}

test "names in the alignment of destructuring targets are references" {
    // Prevents goto, hover and references from missing names in `align(...)` of a destructuring
    // target
    const text =
        \\const n: u29 = 8;
        \\pub fn main() void {
        \\    const k: u29 = 16;
        \\    const a: u32 align(n), const b: u8 align(k) = .{ 1, 2 };
        \\    _ = .{ a, b };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_]struct { []const u8, []const u8 }{ .{ "n), const", "n: u29" }, .{ "k) =", "k: u29" } }) |c| {
        const use: u32 = @intCast(std.mem.indexOf(u8, text, c[0]).?);
        const t = try definition.definition(&r, file, use) orelse return error.NoTarget;
        try testing.expect(std.mem.startsWith(u8, text[t.start..], c[1]));
        _ = try hover.hover(&r, file, use, &.{}, .list) orelse return error.NoHover;
        const def = try definition.defAt(&r, file, @intCast(std.mem.indexOf(u8, text, c[1]).?)) orelse return error.NoDefinition;
        const refs = try search.findReferences(&r, def, .{ .scope = &.{file} });
        try testing.expectEqual(2, refs.len);
        try testing.expectEqual(use, refs[1].start);
    }
}

test "goto on a member of a merged error set reaches the operand that declares it" {
    // Prevents an empty result when the name comes from a named operand of `||`
    const text =
        \\const ReadErr = error{ EndOfStream, Timeout };
        \\const WriteErr = error{ DiskFull, Timeout };
        \\const IoErr = ReadErr || WriteErr;
        \\const AllErr = IoErr || error{Closed};
        \\fn io(x: u32) AllErr!void {
        \\    if (x == 0) return IoErr.DiskFull;
        \\    if (x == 1) return AllErr.DiskFull;
        \\    if (x == 2) return AllErr.Closed;
        \\}
        \\test {
        \\    io(3) catch {};
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_]struct { []const u8, []const u8 }{
        .{ "DiskFull;\n    if (x == 1)", "DiskFull, Timeout" },
        .{ "DiskFull;\n    if (x == 2)", "DiskFull, Timeout" },
        .{ "Closed;", "Closed}" },
    }) |c| {
        const at: u32 = @intCast(std.mem.indexOf(u8, text, c[0]).?);
        for ([_]*const fn (*resolve.Resolver, FileId, u32) resolve.Error!?definition.Target{ definition.definition, definition.declaration }) |find| {
            const t = try find(&r, file, at) orelse {
                std.debug.print("`{s}`: no target\n", .{c[0]});
                return error.NoTarget;
            };
            try testing.expect(std.mem.startsWith(u8, text[t.start..], c[1]));
        }
    }
}

test "goto on a member of a container does not jump to an error of the same name inside it" {
    // Prevents `Http.NotFound` from jumping to `error{NotFound}` in a function of `Http`
    const text =
        \\const Http = struct {
        \\    pub const NotFound: u16 = 404;
        \\    pub fn get() error{NotFound}!void {}
        \\};
        \\const Errno = enum(u16) {
        \\    NOENT = 2,
        \\    pub fn toError(e: Errno) error{NOENT}!void {
        \\        _ = e;
        \\    }
        \\};
        \\const Err = error{ NotFound, Other };
        \\test {
        \\    _ = Http.NotFound;
        \\    _ = Errno.NOENT;
        \\    _ = Err.NotFound;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_]struct { []const u8, []const u8 }{
        .{ "NotFound;\n    _ = Errno", "NotFound: u16" },
        .{ "NOENT;", "NOENT = 2" },
        .{ "NotFound;\n}", "NotFound, Other" },
    }) |c| {
        const at: u32 = @intCast(std.mem.indexOf(u8, text, c[0]).?);
        for ([_]*const fn (*resolve.Resolver, FileId, u32) resolve.Error!?definition.Target{ definition.definition, definition.declaration }) |find| {
            const t = try find(&r, file, at) orelse return error.NoTarget;
            testing.expect(std.mem.startsWith(u8, text[t.start..], c[1])) catch |err| {
                std.debug.print("`{s}`: target `{s}`\n", .{ c[0], text[t.start..t.end] });
                return err;
            };
        }
    }
}

test "type definition of field names in initializers goes to the type of the field" {
    // Prevents a jump to the type of the enclosing initializer
    const text =
        \\const Color = enum { red, green };
        \\const Inner = struct { v: u32 = 0 };
        \\const Outer = struct { inner: Inner = .{}, color: Color = .red };
        \\test {
        \\    const o: Outer = .{ .inner = .{ .v = 1 }, .color = .green };
        \\    const p = Outer{ .inner = .{} };
        \\    _ = .{ o, p };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_]struct { []const u8, ?[]const u8 }{
        .{ "inner = .{ .v", "Inner = struct" },
        .{ "color = .green", "Color = enum" },
        .{ "v = 1", null },
        .{ "inner = .{} }", "Inner = struct" },
    }) |c| {
        const t = try definition.typeDefinition(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?));
        const expected = c[1] orelse {
            try testing.expectEqual(null, t);
            continue;
        };
        try testing.expect(std.mem.startsWith(u8, text[(t orelse return error.NoTarget).start..], expected));
    }
}

/// "file:line" of each target of `find` at the first occurrence of `needle` in `file`, sorted and
/// joined by spaces
fn gotoLines(w: *World, r: *resolve.Resolver, file: FileId, needle: []const u8, comptime find: anytype) ![]const u8 {
    const a = w.arena.allocator();
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    var labels: std.ArrayList([]const u8) = .empty;
    for (try find(r, file, @intCast(std.mem.indexOf(u8, text, needle).?))) |t| {
        const target_text = (try r.ctx.get(database.syntax.SourceText, t.file)).text;
        const line = std.mem.count(u8, target_text[0..t.start], "\n") + 1;
        try labels.append(a, try std.fmt.allocPrint(a, "{s}:{d}", .{ std.fs.path.basename(w.vfs.path(t.file)), line }));
    }
    std.mem.sort([]const u8, labels.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return std.mem.join(a, " ", labels.items);
}

test "goto in generic functions lists the targets under every instance" {
    // Prevents goto from returning only the target under the instance of the first call site
    const types =
        \\//- /p/main.zig module:app
        \\const lib = @import("lib.zig");
        \\const A = struct { len: u32 = 1, pub fn name() []const u8 { return "a"; } };
        \\const B = struct { len: u32 = 2, pub fn name() []const u8 { return "b"; } };
        \\fn show(comptime T: type) []const u8 { return T.name(); }
        \\fn getLen(x: anytype) u32 { return x.len; }
        \\
    ;
    for ([_][]const u8{
        \\test {
        \\    _ = .{ show(A), show(B), getLen(A{}), getLen(B{}), lib.run(A, 1), lib.run(B, 2) };
        \\}
        ,
        \\test {
        \\    _ = .{ show(B), show(A), getLen(B{}), getLen(A{}), lib.run(B, 2), lib.run(A, 1) };
        \\}
    }) |calls| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const f = try w.fixture(try std.mem.concat(w.arena.allocator(), u8, &.{
            types, calls,
            \\
            \\//- /p/lib.zig in:app
            \\pub fn run(comptime Q: type, key: u32) []const u8 {
            \\    _ = key;
            \\    return Q.name();
            \\}
        }));
        const main = f.file("/p/main.zig");
        const lib = f.file("/p/lib.zig");
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        for ([_]struct { FileId, []const u8, []const u8 }{
            .{ main, "name(); }", "main.zig:2 main.zig:3" },
            .{ main, "len; }", "main.zig:2 main.zig:3" },
            .{ lib, "name();", "main.zig:2 main.zig:3" },
        }) |c| {
            try testing.expectEqualStrings(c[2], try gotoLines(&w, &r, c[0], c[1], definition.definitionTargets));
            try testing.expectEqualStrings(c[2], try gotoLines(&w, &r, c[0], c[1], definition.declarationTargets));
        }
        try testing.expectEqualStrings("main.zig:2 main.zig:3", try gotoLines(&w, &r, main, "x.len", definition.typeDefinitionTargets));
        try testing.expectEqualStrings("main.zig:2 main.zig:3", try gotoLines(&w, &r, main, "T.name", definition.typeDefinitionTargets));
        try testing.expectEqualStrings("main.zig:2 main.zig:3", try gotoLines(&w, &r, lib, "Q.name", definition.typeDefinitionTargets));
    }
}

test "hover in generic bodies follows the declarations under the other instances" {
    // Prevents hover from showing only the declaration under one instance where goto lists the
    // declarations under the others
    const text =
        \\const A = struct {
        \\    /// The files of A
        \\    pub const files = [_][]const u8{"a.txt"};
        \\    pub const empty: A = .{};
        \\    len: u32 = 1,
        \\};
        \\const B = struct {
        \\    /// The files of B
        \\    pub const files = [_][]const u8{ "b.txt", "c.txt" };
        \\    pub const empty: B = .{};
        \\    len: u16 = 2,
        \\};
        \\fn count(comptime T: type) usize {
        \\    return T.files.len;
        \\}
        \\fn make(comptime T: type) T {
        \\    return .{ .len = 3 };
        \\}
        \\fn none(comptime T: type) T {
        \\    return .empty;
        \\}
        \\fn same(comptime T: type) usize {
        \\    return @sizeOf(T) + A.files.len;
        \\}
        \\test {
        \\    _ = count(A);
        \\    _ = count(B);
        \\    _ = count(A);
        \\    _ = make(A);
        \\    _ = make(B);
        \\    _ = none(A);
        \\    _ = none(B);
        \\    _ = same(A);
        \\    _ = same(B);
        \\}
        \\const E1 = enum { alpha, beta };
        \\const E2 = enum { gamma, alpha };
        \\fn pick(comptime E: type) E {
        \\    return .alpha;
        \\}
        \\test {
        \\    _ = pick(E1);
        \\    _ = pick(E2);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_]struct { []const u8, hover.Instances, []const u8 }{
        .{
            "files.len;\n}\nfn make", .list,
            \\```zig
            \\const files: [1][]const u8 = .{ "a.txt" }
            \\```
            \\
            \\inferred from the call at main.zig:26
            \\
            \\The files of A
            \\
            \\Under other instances:
            \\
            \\- `const files: [2][]const u8` at main.zig:9, inferred from the call at main.zig:27
        },
        .{
            "files.len;\n}\nfn make", .full,
            \\```zig
            \\const files: [1][]const u8 = .{ "a.txt" }
            \\```
            \\
            \\inferred from the call at main.zig:26
            \\
            \\The files of A
            \\
            \\---
            \\
            \\```zig
            \\const files: [2][]const u8 = .{ "b.txt", "c.txt" }
            \\```
            \\
            \\inferred from the call at main.zig:27
            \\
            \\The files of B
        },
        .{
            "len = 3", .list,
            \\```zig
            \\len: u32
            \\```
            \\
            \\inferred from the call at main.zig:29
            \\
            \\Under other instances:
            \\
            \\- `len: u16` at main.zig:11, inferred from the call at main.zig:30
        },
        .{
            "empty;\n}", .list,
            \\```zig
            \\const empty: A = .{ .len = 1 }
            \\```
            \\
            \\inferred from the call at main.zig:31
            \\
            \\Under other instances:
            \\
            \\- `const empty: B` at main.zig:10, inferred from the call at main.zig:32
        },
        .{
            "alpha;\n}", .list,
            \\```zig
            \\alpha: E1 = .alpha
            \\```
            \\
            \\inferred from the call at main.zig:42
            \\
            \\Under other instances:
            \\
            \\- `alpha: E2` at main.zig:37, inferred from the call at main.zig:43
        },
        // The same declaration under every instance: nothing follows
        .{
            "files.len;\n}\ntest", .list,
            \\```zig
            \\const files: [1][]const u8 = .{ "a.txt" }
            \\```
            \\
            \\The files of A
        },
    }) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, c[1]) orelse {
            std.debug.print("no hover at `{s}` ({t})\n", .{ c[0], c[1] });
            return error.NoHover;
        };
        testing.expectEqualStrings(c[2], info.text) catch |err| {
            std.debug.print("hover at `{s}` ({t})\n", .{ c[0], c[1] });
            return err;
        };
    }
}

test "hover in generic bodies on names whose result type is a parameter" {
    // Prevents a null hover on `.len` in `.{ .len = 3 }` and `@EnumLiteral()` for `.empty` returned as `T`, while goto resolves both
    const text =
        \\const A = struct {
        \\    /// The empty A
        \\    pub const empty: A = .{};
        \\    len: u32 = 1,
        \\};
        \\const E = enum { alpha, beta };
        \\fn make(comptime T: type) T {
        \\    return .{ .len = 3 };
        \\}
        \\fn none(comptime T: type) T {
        \\    return .empty;
        \\}
        \\fn pick(comptime T: type) T {
        \\    return .alpha;
        \\}
        \\test {
        \\    _ = make(A);
        \\    _ = none(A);
        \\    _ = pick(E);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_]struct { []const u8, []const u8 }{
        .{ "len = 3", "```zig\nlen: u32\n```\n\ninferred from the call at main.zig:17" },
        .{ "empty;", "```zig\nconst empty: A = .{ .len = 1 }\n```\n\ninferred from the call at main.zig:18\n\nThe empty A" },
        .{ "alpha;", "```zig\nalpha: E = .alpha\n```\n\ninferred from the call at main.zig:19" },
    }) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list)) orelse {
            std.debug.print("no hover at `{s}`\n", .{c[0]});
            return error.NoHover;
        };
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}
test "type definition of fields typed by the parameter of a generic container" {
    // Prevents an empty result on `self.items` when only the type of `self` was seeded
    const text =
        \\const Point = struct { x: i32 = 0 };
        \\fn Stack(comptime T: type) type {
        \\    return struct {
        \\        items: [4]T = undefined,
        \\        top_: T = undefined,
        \\        const Self = @This();
        \\        fn top(self: *Self) T {
        \\            const last = self.items[0];
        \\            _ = self.top_;
        \\            return last;
        \\        }
        \\    };
        \\}
        \\fn firstOf(st: anytype) void {
        \\    _ = st.items;
        \\}
        \\test {
        \\    var s: Stack(Point) = .{};
        \\    _ = s.top();
        \\    firstOf(s);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_][]const u8{ "items[0]", "top_;", "last;", "items;" }) |needle| {
        const t = try definition.typeDefinition(&r, file, @intCast(std.mem.indexOf(u8, text, needle).?)) orelse {
            std.debug.print("`{s}`: no target\n", .{needle});
            return error.NoTarget;
        };
        try testing.expect(std.mem.startsWith(u8, text[t.start..], "Point = struct"));
    }
}

test "goto, hover and symbols on the types of unnamed extern parameters" {
    // Prevents the empty binding of an unnamed parameter from capturing the first token of its type
    const text =
        \\const Foo = extern struct { a: u32 };
        \\const c = struct {
        \\    pub const fd_t = c_int;
        \\};
        \\extern fn ext(Foo, *const Foo) void;
        \\extern fn prim(c_int) void;
        \\extern fn qual(c.fd_t) void;
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = struct {
        fn f(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, text, needle).?);
        }
    }.f;
    for ([_]struct { []const u8, []const u8 }{
        .{ "Foo, *const", "Foo = extern" },
        .{ "Foo) void", "Foo = extern" },
        .{ "c.fd_t", "c = struct" },
    }) |c| {
        const def = (try definition.definition(&r, file, at(c[0]))) orelse return error.NoDefinition;
        try testing.expect(std.mem.startsWith(u8, text[def.start..], c[1]));
        const decl = (try definition.declaration(&r, file, at(c[0]))) orelse return error.NoDeclaration;
        try testing.expect(std.mem.startsWith(u8, text[decl.start..], c[1]));
        const symbol = (try definition.symbolAt(&r, file, at(c[0]))) orelse return error.NoSymbol;
        try testing.expect(symbol == .def and symbol.def == .item);
    }
    try testing.expectEqual(null, try definition.definition(&r, file, at("c_int) void")));
    try testing.expectEqual(null, try definition.symbolAt(&r, file, at("c_int) void")));
    const info = (try hover.hover(&r, file, at("Foo, *const"), &.{}, .list)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst Foo = struct\n```", info.text);
}

test "goto declaration of labels and field names in initializers" {
    const text =
        \\const Point = struct { x: i32, y: i32 };
        \\fn f(n: u32) Point {
        \\    const v = blk: {
        \\        if (n == 0) break :blk 1;
        \\        break :blk 2;
        \\    };
        \\    outer: for (0..n) |_| {
        \\        while (true) continue :outer;
        \\    }
        \\    const p: Point = .{ .x = v, .y = 0 };
        \\    return Point{ .x = p.x, .y = 1 };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "blk 1", 0, "blk: {" },
        .{ "blk 2", 0, "blk: {" },
        .{ "blk: {", 0, "blk: {" },
        .{ "outer;", 0, "outer: for" },
        .{ ".x = v", 1, "x: i32" },
        .{ ".y = 0", 1, "y: i32" },
        .{ ".x = p", 1, "x: i32" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).? + c[1];
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[2])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..@min(text.len, t.start + 20)] });
            return err;
        };
    }
}

test "goto declaration of enum literals compared with enums and tagged unions" {
    const text =
        \\const E = enum { a, b };
        \\const U = union(enum) { int: u32, none };
        \\fn tag(x: u32) E {
        \\    return if (x == 0) .a else .b;
        \\}
        \\fn f(e: E, u: U) bool {
        \\    const x: E = .a;
        \\    if (u == .none) return false;
        \\    if (u != .int) return false;
        \\    if (.b == e) return true;
        \\    return e == .b and tag(1) != .a and x == .a;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "a;\n    if", "a, b }" },
        .{ "none) return", "none };" },
        .{ "int) return", "int: u32" },
        .{ "b and", "b }" },
        .{ "a and", "a, b }" },
        .{ "b == e", "b }" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[1])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..@min(text.len, t.start + 20)] });
            return err;
        };
    }
}

test "named error sets: goto and completion of their members" {
    const text =
        \\pub const Error = error{ MissingValue, InvalidArgument };
        \\const Alias = Error;
        \\fn f(e: Error) bool {
        \\    return e == Error.MissingValue or e == Alias.InvalidArgument;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "MissingValue or", "MissingValue, Invalid" },
        .{ "InvalidArgument;", "InvalidArgument }" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[1])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..@min(text.len, t.start + 20)] });
            return err;
        };
    }
    const items = (try completion.complete(&r, file, @intCast(std.mem.indexOf(u8, text, "MissingValue or").?), .{ .auto_import = false })).items;
    var found = false;
    for (items) |it| if (std.mem.eql(u8, it.label, "InvalidArgument")) {
        found = true;
    };
    try testing.expect(found);
}

test "inlay hint options" {
    const text =
        \\fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\fn one(n: u32) u32 {
        \\    return n;
        \\}
        \\const P = struct { x: u32 };
        \\fn f(dest: []u8, src: []const u8) void {
        \\    const a: u32 = 1;
        \\    const v = add(a, 2);
        \\    const p: P = .{ .x = one(v) };
        \\    @memcpy(dest, src);
        \\    _ = p;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { inlay_hints.Options, []const u8 }{
        // Default: types of local variables and fields; parameter names, with no hints for `a` and
        // `dest`, which have the same names as the arguments, or for the single-argument call
        // `one(v)`
        .{ .{}, ": u32 b: : u32 source:" },
        .{ .{ .types = false }, "b: : u32 source:" },
        .{ .{ .field_types = false }, ": u32 b: source:" },
        .{ .{ .parameters = false }, ": u32 : u32" },
        .{ .{ .builtin_parameters = false }, ": u32 b: : u32" },
        .{ .{ .exclude_single_argument = false }, ": u32 b: : u32 n: source:" },
        .{ .{ .hide_redundant_param_names = false }, ": u32 a: b: : u32 dest: source:" },
    };
    for (cases, 0..) |c, i| {
        const hints = try inlay_hints.inlayHints(&r, file, 0, @intCast(text.len), c[0]);
        var labels: std.ArrayList([]const u8) = .empty;
        for (hints) |h| try labels.append(w.arena.allocator(), h.label);
        testing.expectEqualStrings(c[1], try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
            std.debug.print("case {d}\n", .{i});
            return err;
        };
    }
}

/// Inserts the hints at their positions in the source: a parameter name hint is followed by a
/// space, as shown in the editor
fn inlaid(w: *World, file: FileId, text: []const u8, opts: inlay_hints.Options) ![]const u8 {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    const hints = try inlay_hints.inlayHints(&r, file, 0, @intCast(text.len), opts);
    const a = w.arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    for (hints) |h| {
        try out.appendSlice(a, text[pos..h.offset]);
        try out.appendSlice(a, h.label);
        if (h.kind == .parameter) try out.append(a, ' ');
        pos = h.offset;
    }
    try out.appendSlice(a, text[pos..]);
    return out.items;
}

test "inlay hints: the length limit cuts comptime strings on whole characters" {
    // A cut must not split a UTF-8 sequence into `\xNN` escapes
    const text =
        \\fn Tag(comptime name: []const u8) type {
        \\    return struct { v: u8 = 0, const tag = name; };
        \\}
        \\fn Label(comptime text: []const u8) type {
        \\    return struct { v: u8 = 0, const tag = text; };
        \\}
        \\pub fn main() void {
        \\    const a = Tag("a中文中文中文中文中文中文"){};
        \\    const b = Tag("😀😀😀😀😀😀😀😀😀😀😀😀😀😀"){};
        \\    const c = Label("café crème brûlée façade"){};
        \\    _ = .{ a, b, c };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const hinted = try inlaid(&w, file, text, .{ .parameters = false, .field_types = false });
    try testing.expect(std.mem.indexOf(u8, hinted, "const a: Tag(\"a中文中文中文中文中文中文\") =") != null);
    try testing.expect(std.mem.indexOf(u8, hinted, "const b: Tag(\"😀😀😀😀😀😀😀😀😀😀😀😀😀😀\") =") != null);
    for (1..41) |limit| {
        const cut = try inlaid(&w, file, text, .{ .parameters = false, .field_types = false, .max_length = @intCast(limit) });
        try testing.expect(std.unicode.utf8ValidateSlice(cut));
        testing.expect(std.mem.indexOf(u8, cut, "\\x") == null) catch |err| {
            std.debug.print("max_length {d}:\n{s}\n", .{ limit, cut });
            return err;
        };
    }
}

test "inlay hints: parameter names only inside the requested range" {
    // Arguments of an intersecting call outside the range get no hints
    const text =
        \\fn three(alpha: u32, beta: u32, gamma: u32) u32 {
        \\    return alpha + beta + gamma;
        \\}
        \\pub fn main() void {
        \\    const total = three(
        \\        1,
        \\        2,
        \\        3,
        \\    );
        \\    var buf: [2]u8 = undefined;
        \\    @memcpy(
        \\        buf[0..1],
        \\        "a",
        \\    );
        \\    _ = total;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at = struct {
        fn f(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, text, needle).?);
        }
    }.f;
    const cases = [_]struct { u32, u32, []const u8 }{
        .{ at("        3,"), at("    );"), "gamma:" },
        .{ 0, at("        1,"), ": u32" },
        .{ at("    );"), at("    var buf"), "" },
        .{ at("        \"a\""), at("    _ = total"), "source:" },
    };
    for (cases) |c| {
        var labels: std.ArrayList([]const u8) = .empty;
        for (try inlay_hints.inlayHints(&r, file, c[0], c[1], .{})) |h| try labels.append(w.arena.allocator(), h.label);
        try testing.expectEqualStrings(c[2], try std.mem.join(w.arena.allocator(), " ", labels.items));
    }
}

test "inlay hints: field types in initializers that have a result type" {
    const text =
        \\const Point = struct { x: i32, y: i32 = 0 };
        \\const Wrap = struct { p: Point };
        \\const U = union(enum) { a: u8, b: bool };
        \\fn List(comptime T: type) type {
        \\    return struct { items: []T, len: usize };
        \\}
        \\fn take(p: Point) void {
        \\    _ = p;
        \\}
        \\fn f() !?Point {
        \\    const p = Point{ .x = 1, .y = 2 };
        \\    take(.{ .x = 3 });
        \\    const u: U = .{ .b = true };
        \\    const l: List(u8) = .{ .items = &.{}, .len = 0 };
        \\    const w: Wrap = .{ .p = .{ .x = 4 } };
        \\    const anon = .{ .x = 5 };
        \\    _ = .{ p, u, l, w, anon };
        \\    return .{ .x = 6, .y = 7 };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    // Field types come from the result type of the initializer (the written type, a parameter, an
    // annotation, an enclosing field, the return type without error union and optional), and for
    // generic containers from the instance; anonymous initializers without a result type get no
    // hints
    try testing.expectEqualStrings(
        \\const Point = struct { x: i32, y: i32 = 0 };
        \\const Wrap = struct { p: Point };
        \\const U = union(enum) { a: u8, b: bool };
        \\fn List(comptime T: type) type {
        \\    return struct { items: []T, len: usize };
        \\}
        \\fn take(p: Point) void {
        \\    _ = p;
        \\}
        \\fn f() !?Point {
        \\    const p = Point{ .x: i32 = 1, .y: i32 = 2 };
        \\    take(.{ .x: i32 = 3 });
        \\    const u: U = .{ .b: bool = true };
        \\    const l: List(u8) = .{ .items: []u8 = &.{}, .len: usize = 0 };
        \\    const w: Wrap = .{ .p: Point = .{ .x: i32 = 4 } };
        \\    const anon = .{ .x = 5 };
        \\    _ = .{ p, u, l, w, anon };
        \\    return .{ .x: i32 = 6, .y: i32 = 7 };
        \\}
        \\
    , try inlaid(&w, file, text, .{ .types = false, .parameters = false }));
}

test "hover shows tuples whose fields are all comptime by value and does not truncate" {
    const text =
        \\const A = struct {};
        \\const B = struct {};
        \\const Alpha_Long_Name = struct {};
        \\const Beta_Long_Name = struct {};
        \\const qs = .{ A, B };
        \\const point = .{ .x = 1, .y = true };
        \\const long = .{ Alpha_Long_Name, Beta_Long_Name, Alpha_Long_Name, Beta_Long_Name, Alpha_Long_Name, Beta_Long_Name, Alpha_Long_Name, Beta_Long_Name };
        \\const msg = "a message that is longer than sixty-four bytes, all of it shown in hover";
        \\const name_len = @typeName(@TypeOf(.{ @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0), @as(u8, 0) })).len;
        \\const Outer = struct { inner: struct { deep: struct { z: u8 }, next: ?*const @This() } };
        \\fn f(a: u8, o: Outer) void {
        \\    const many = .{ a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a };
        \\    const in = o.inner;
        \\    _ = .{ many, in };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    // Types in inlay hints are at most about `max_length` characters (25 by default): when the
    // limit is already reached before the next field is written, the rest is shown as `…`; 0 means
    // no limit
    const hinted = try inlaid(&w, file, text, .{ .parameters = false, .field_types = false });
    try testing.expect(std.mem.indexOf(u8, hinted, "const many: struct { u8, u8, u8, u8, … } =") != null);
    const unlimited = try inlaid(&w, file, text, .{ .parameters = false, .field_types = false, .max_length = 0 });
    try testing.expect(std.mem.indexOf(u8, unlimited, "const many: struct { u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8 } =") != null);

    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        // The type is fully determined by the value: only the value is shown
        .{ "qs =", "const qs = .{ A, B }" },
        .{ "point =", "const point = .{ .x = 1, .y = true }" },
        // hover does not truncate: long values, strings over 64 bytes and tuples with more than 16
        // fields are all shown in full
        .{ "long =", "const long = .{\n    Alpha_Long_Name, Beta_Long_Name, Alpha_Long_Name, Beta_Long_Name,\n    Alpha_Long_Name, Beta_Long_Name, Alpha_Long_Name, Beta_Long_Name,\n}" },
        .{ "msg =", "const msg: *const [72:0]u8 = \"a message that is longer than sixty-four bytes, all of it shown in hover\"" },
        .{ "many =", "const many: struct { u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8 }" },
        // Nested anonymous containers are expanded too; only self-references are shown as `{...}`
        .{ "in =", "const in: struct { deep: struct { z: u8 }, next: ?*const struct {...} }" },
        // `@typeName` is the full name (as in the compiler, 315 bytes)
        .{ "name_len =", "const name_len: usize = 315" },
    };
    for (cases) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list)).?;
        testing.expectEqualStrings(try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}\n```", .{c[1]}), info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "hover writes the void value inside aggregates and union values as {}" {
    // Prevents writing it as `void`, which in Zig syntax is the type, not the value
    const text =
        \\const State = union(enum) {
        \\    idle,
        \\    running: u32,
        \\};
        \\const initial: State = .idle;
        \\const S2 = struct { a: void = {}, b: bool = true };
        \\const s2: S2 = .{};
        \\const tup = .{ {}, true };
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "initial:", "const initial: State = .{ .idle = {} }" },
        .{ "s2:", "const s2: S2 = .{ .a = {}, .b = true }" },
        .{ "tup =", "const tup = .{ {}, true }" },
    };
    for (cases) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list)).?;
        testing.expectEqualStrings(try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}\n```", .{c[1]}), info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "hover shows comptime-known bool, null, undefined and void values" {
    // Prevents omitting these values while integers, enums and optionals show theirs
    const text =
        \\const t = true;
        \\const n: ?u8 = null;
        \\const st = !t;
        \\const u: u8 = undefined;
        \\const v = {};
        \\fn f() void {
        \\    var b = false;
        \\    b = !b;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "t =", "const t: bool = true" },
        .{ "n:", "const n: ?u8 = null" },
        .{ "st =", "const st: bool = false" },
        .{ "u:", "const u: u8 = undefined" },
        .{ "v =", "const v: void = {}" },
        // A runtime variable has no comptime-known value
        .{ "b = false", "var b: bool" },
    };
    for (cases) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list)).?;
        testing.expectEqualStrings(try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}\n```", .{c[1]}), info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "hover and completion details bound large comptime values and mark the cut" {
    // Prevents a large binary `@embedFile` constant from producing a multi-megabyte hover
    const text =
        \\const blob = @embedFile("assets/blob.bin");
        \\const head = blob[0..4096];
        \\const table: [3000]u16 = @splat(7);
        \\const small = "fits";
        \\fn f() usize {
        \\    return blob.len + head.len + table.len + small.len;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const bytes = try w.arena.allocator().alloc(u8, 1 << 20);
    for (bytes, 0..) |*b, i| b.* = @truncate(i *% 7919);
    _ = try w.add("/p/assets/blob.bin", bytes);
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const roots: []const []const u8 = &.{test_path.native("/p")};

    // The value of `@embedFile` is shown as the call, with the file and its size
    const blob_code = std.fmt.comptimePrint("*const [1048576:0]u8 = @embedFile(\"assets/blob.bin\")\n```\n\nEmbedded file `assets{c}blob.bin`: 1048576 bytes", .{std.fs.path.sep});
    for ([_][]const u8{ "blob =", "blob.len" }) |needle| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, needle).?), roots, .list)).?;
        try testing.expectEqualStrings("```zig\nconst blob: " ++ blob_code, info.text);
    }
    const call = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "embedFile").?), roots, .list)).?.text;
    try testing.expect(std.mem.endsWith(u8, call, "Inferred result:\n\n```zig\n" ++ blob_code));
    // `completionItem/resolve` of an auto-import candidate: `blob` is the first member
    try testing.expectEqualStrings(
        "const blob: *const [1048576:0]u8 = @embedFile(\"assets/blob.bin\")",
        (try completion.describe(&r, file, .{ .decl = .{ .file = file, .item = 0 } })).detail,
    );

    // A value computed from the content is cut, with the total
    const head = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "head =").?), roots, .list)).?.text;
    try testing.expect(head.len < 4096);
    try testing.expect(std.mem.startsWith(u8, head, "```zig\nconst head: *const [4096]u8 = \"\\x00\\xef\\xde"));
    try testing.expect(std.mem.endsWith(u8, head, "…\" (4096 bytes total)\n```"));
    const table = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "table:").?), roots, .list)).?.text;
    try testing.expect(table.len < 4096);
    try testing.expect(std.mem.startsWith(u8, table, "```zig\nconst table: [3000]u16 = .{\n    7, 7, "));
    try testing.expect(std.mem.endsWith(u8, table, ",\n    … (3000 total)\n}\n```"));
    // Values within the limit are shown in full
    const small = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "small =").?), roots, .list)).?.text;
    try testing.expectEqualStrings("```zig\nconst small: *const [4:0]u8 = \"fits\"\n```", small);
}

test "hover breaks values too wide for one line, completion details keep them on one line" {
    const text =
        \\const Pair = struct { name: []const u8, value: u32 };
        \\const short = [_][2][]const u8{ .{ "a", "b" }, .{ "c", "d" } };
        \\const types = [_][2][]const u8{
        \\    .{ ".html, with comma", "text/html" },
        \\    .{ ".webmanifest", "application/manifest+json" },
        \\    .{ ".xhtml", "application/xhtml+xml" },
        \\};
        \\const pairs = [_]Pair{
        \\    .{ .name = "first entry of the table", .value = 1 },
        \\    .{ .name = "second entry of the table, which does not fit on a line of its own", .value = 2 },
        \\};
        \\const words = [_][]const u8{ "first word", "second word", "third word", "fourth word", "fifth word", "sixth word", "seventh word" };
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);

    const cases = [_]struct { []const u8, []const u8 }{
        .{
            "short =",
            \\const short: [2][2][]const u8 = .{ .{ "a", "b" }, .{ "c", "d" } }
        },
        .{
            "types =",
            \\const types: [3][2][]const u8 = .{
            \\    .{ ".html, with comma", "text/html" },
            \\    .{ ".webmanifest", "application/manifest+json" },
            \\    .{ ".xhtml", "application/xhtml+xml" },
            \\}
        },
        .{
            "pairs =",
            \\const pairs: [2]Pair = .{
            \\    .{ .name = "first entry of the table", .value = 1 },
            \\    .{
            \\        .name = "second entry of the table, which does not fit on a line of its own",
            \\        .value = 2,
            \\    },
            \\}
        },
        .{
            "words =",
            \\const words: [7][]const u8 = .{
            \\    "first word", "second word", "third word", "fourth word", "fifth word",
            \\    "sixth word", "seventh word",
            \\}
        },
    };
    for (cases) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list)).?;
        try testing.expectEqualStrings(try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}\n```", .{c[1]}), info.text);
    }

    const item: u32 = for ((try r.itemTree(file)).items, 0..) |it, i| {
        if (it.name) |n| if (std.mem.eql(u8, n, "types")) break @intCast(i);
    } else unreachable;
    const detail = (try completion.describe(&r, file, .{ .decl = .{ .file = file, .item = item } })).detail;
    try testing.expectEqualStrings(
        \\const types: [3][2][]const u8 = .{ .{ ".html, with comma", "text/html" }, .{ ".webmanifest", "application/manifest+json" }, .{ ".xhtml", "application/xhtml+xml" } }
    , detail);
}

test "hover shows the file and size of @embedFile values, and the content of short text" {
    const text =
        \\pub const notes = @embedFile("notes.txt");
        \\const bin = @embedFile("small.bin");
        \\const long = @embedFile("long.txt");
        \\const wide = @embedFile("wide.txt");
        \\const typed: []const u8 = @embedFile("notes.txt");
        \\const name = "small.bin";
        \\const by_name = @embedFile(name);
        \\const missing = @embedFile("missing.txt");
        \\fn f() usize {
        \\    const local = @embedFile("small.bin");
        \\    return local.len;
        \\}
        \\
    ;
    const notes = "Hello, `world`!\n```\nfenced\n```\n";
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const arena = w.arena.allocator();
    _ = try w.add("/p/notes.txt", notes);
    _ = try w.add("/p/small.bin", "\x00\x01ab");
    // One character over the limit, and exactly the limit in two-byte characters
    const long = try arena.alloc(u8, 2001);
    @memset(long, 'a');
    _ = try w.add("/p/long.txt", long);
    const wide = try arena.alloc(u8, 4000);
    for (0..2000) |i| @memcpy(wide[2 * i ..][0..2], "é");
    _ = try w.add("/p/wide.txt", wide);
    const file = (try w.add("/p/main.zig", text)).file;
    const other_text =
        \\const main = @import("main.zig");
        \\const n = main.notes.len;
        \\
    ;
    const other = (try w.add("/p/other.zig", other_text)).file;
    var ctx = w.db.beginRead(arena);
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const roots: []const []const u8 = &.{test_path.native("/p")};

    // Text: the content follows, in a fence longer than its backtick runs
    const notes_hover = "```zig\nconst notes: *const [31:0]u8 = @embedFile(\"notes.txt\")\n```\n\nEmbedded file `notes.txt`: 31 bytes\n\n````text\n" ++ notes ++ "````";
    try testing.expectEqualStrings(notes_hover, (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "notes =").?), roots, .list)).?.text);
    // From another file, relative to the workspace folder
    try testing.expectEqualStrings(notes_hover, (try hover.hover(&r, other, @intCast(std.mem.indexOf(u8, other_text, "notes.len").?), roots, .list)).?.text);
    // Outside the workspace folders, the absolute path
    const outside = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "notes =").?), &.{}, .list)).?.text;
    try testing.expect(std.mem.indexOf(u8, outside, "Embedded file `" ++ comptime test_path.native("/p/notes.txt") ++ "`: 31 bytes") != null);
    // The type annotation is kept
    try testing.expectEqualStrings(
        "```zig\nconst typed: []const u8 = @embedFile(\"notes.txt\")\n```\n\nEmbedded file `notes.txt`: 31 bytes\n\n````text\n" ++ notes ++ "````",
        (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "typed:").?), roots, .list)).?.text,
    );
    // Binary content and text over the limit are not shown
    const bin_hover = "```zig\nconst bin: *const [4:0]u8 = @embedFile(\"small.bin\")\n```\n\nEmbedded file `small.bin`: 4 bytes";
    try testing.expectEqualStrings(bin_hover, (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "bin =").?), roots, .list)).?.text);
    try testing.expectEqualStrings(
        "```zig\nconst long: *const [2001:0]u8 = @embedFile(\"long.txt\")\n```\n\nEmbedded file `long.txt`: 2001 bytes",
        (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "long =").?), roots, .list)).?.text,
    );
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "```zig\nconst wide: *const [4000:0]u8 = @embedFile(\"wide.txt\")\n```\n\nEmbedded file `wide.txt`: 4000 bytes\n\n```text\n{s}\n```", .{wide}),
        (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "wide =").?), roots, .list)).?.text,
    );
    // A path known at comptime, and a local constant
    try testing.expectEqualStrings(
        "```zig\nconst by_name: *const [4:0]u8 = @embedFile(\"small.bin\")\n```\n\nEmbedded file `small.bin`: 4 bytes",
        (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "by_name =").?), roots, .list)).?.text,
    );
    try testing.expectEqualStrings(
        "```zig\nconst local: *const [4:0]u8 = @embedFile(\"small.bin\")\n```\n\nEmbedded file `small.bin`: 4 bytes",
        (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "local.len").?), roots, .list)).?.text,
    );
    // A file that does not exist has no value
    try testing.expectEqualStrings("```zig\nconst missing: unknown\n```", (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "missing =").?), roots, .list)).?.text);

    // Completion details show the call without the content
    const tree = try r.itemTree(file);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "notes", "const notes: *const [31:0]u8 = @embedFile(\"notes.txt\")" },
        .{ "bin", "const bin: *const [4:0]u8 = @embedFile(\"small.bin\")" },
        .{ "typed", "const typed: []const u8 = @embedFile(\"notes.txt\")" },
    };
    for (cases) |c| {
        const item = for (tree.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.name orelse "", c[0])) break i;
        } else unreachable;
        try testing.expectEqualStrings(c[1], (try completion.describe(&r, other, .{ .decl = .{ .file = file, .item = @intCast(item) } })).detail);
    }
}

test "hover on a constant aliasing a container shows the aliased type" {
    // Prevents an alias from reading like the definition (`const P2 = struct`)
    const text =
        \\const other = @import("other.zig");
        \\/// A point
        \\const Point = struct { x: i32 };
        \\const P2 = Point;
        \\fn List(comptime T: type) type {
        \\    return struct { items: []T };
        \\}
        \\const L = List(u8);
        \\const Foo = other.Foo;
        \\const Choice = if (@sizeOf(usize) == 8) struct { a: u8 } else struct { a: u16 };
        \\const Holder = struct {
        \\    const Self = @This();
        \\    v: u8,
        \\    fn get(self: Self) u8 {
        \\        return self.v;
        \\    }
        \\};
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/other.zig", "pub const Foo = struct { y: u8 = 0 };\n");
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "Point = struct", "const Point = struct\n```\n\nA point" },
        .{ "P2 =", "const P2: type = Point" },
        .{ "L =", "const L: type = List(u8)" },
        .{ "Foo =", "const Foo: type = Foo" },
        .{ "Choice =", "const Choice = struct" },
        .{ "Self =", "const Self: type = Holder" },
        .{ "Self) u8", "const Self: type = Holder" },
    };
    for (cases) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list)).?;
        const expected = try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}{s}", .{ c[1], if (std.mem.indexOfScalar(u8, c[1], '`') == null) "\n```" else "" });
        testing.expectEqualStrings(expected, info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "anonymous containers are shown by content, and their type hints only when enabled" {
    const text =
        \\const Kind = union(enum) { compile: struct { root: u32 }, none };
        \\const S = struct { inner: packed struct { x: u8 }, list: []const struct { y: u8, next: ?*const @This() } };
        \\const B = if (@sizeOf(usize) == 8) struct { b: u8 } else struct { b: u16 };
        \\fn Ret(comptime n: u8) type {
        \\    return struct { r: [n]u8 };
        \\}
        \\fn f(s: S) void {
        \\    const k: Kind = .{ .compile = .{ .root = 1 } };
        \\    const i = s.inner;
        \\    const l = s.list;
        \\    var v: struct { e: enum { a, b } } = .{ .e = .a };
        \\    const b: B = .{ .b = 1 };
        \\    const L = struct { q: u8 };
        \\    const q = L{ .q = 1 };
        \\    const r = Ret(2){ .r = .{ 1, 2 } };
        \\    _ = .{ k, i, l, &v, b, q, r };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const body = struct {
        fn of(annotated: []const u8) []const u8 {
            return annotated[std.mem.indexOf(u8, annotated, "fn f(").?..];
        }
    }.of;
    // Containers in the type annotations of fields and variables have no name and are shown by
    // content (containers that recur inside them are shown as `{...}`); containers that are a
    // member's value or are picked by `if`, containers in `return` and containers of local
    // constants are named after the member
    try testing.expectEqualStrings(
        \\fn f(s: S) void {
        \\    const k: Kind = .{ .compile: struct { root: u32 } = .{ .root: u32 = 1 } };
        \\    const i: packed struct { x: u8 } = s.inner;
        \\    const l: []const struct { y: u8, next: ?*const struct {...} } = s.list;
        \\    var v: struct { e: enum { a, b } } = .{ .e: enum { a, b } = .a };
        \\    const b: B = .{ .b: u8 = 1 };
        \\    const L = struct { q: u8 };
        \\    const q: L = L{ .q: u8 = 1 };
        \\    const r: Ret(2) = Ret(2){ .r: [2]u8 = .{ 1, 2 } };
        \\    _ = .{ k, i, l, &v, b, q, r };
        \\}
        \\
    , body(try inlaid(&w, file, text, .{ .anonymous_containers = true, .parameters = false })));
    // By default, hints whose types contain anonymous containers are not shown
    try testing.expectEqualStrings(
        \\fn f(s: S) void {
        \\    const k: Kind = .{ .compile = .{ .root: u32 = 1 } };
        \\    const i = s.inner;
        \\    const l = s.list;
        \\    var v: struct { e: enum { a, b } } = .{ .e = .a };
        \\    const b: B = .{ .b: u8 = 1 };
        \\    const L = struct { q: u8 };
        \\    const q: L = L{ .q: u8 = 1 };
        \\    const r: Ret(2) = Ret(2){ .r: [2]u8 = .{ 1, 2 } };
        \\    _ = .{ k, i, l, &v, b, q, r };
        \\}
        \\
    , body(try inlaid(&w, file, text, .{ .parameters = false })));
    // hover is not affected by the inlay hints configuration
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "i = s.inner").?), &.{}, .list)).?;
    try testing.expectEqualStrings("```zig\nconst i: packed struct { x: u8 }\n```", info.text);
}

test "inlay hints: builtin parameter names" {
    const text =
        \\fn f(buf: []u8, data: []const u8, ptr: *u32, x: u64) void {
        \\    @memcpy(buf, data);
        \\    _ = @cmpxchgStrong(u32, ptr, 1, 2, .seq_cst, .monotonic);
        \\    _ = @divExact(x, 2);
        \\    _ = @as(u32, @intCast(x));
        \\    @panic("unreachable");
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    // Parameter names drop the `comptime` / `noalias` prefix; no hints for `@divExact` and `@as`;
    // no hints for `ptr`, which has the same name, or for single-argument calls
    try testing.expectEqualStrings(
        \\fn f(buf: []u8, data: []const u8, ptr: *u32, x: u64) void {
        \\    @memcpy(dest: buf, source: data);
        \\    _ = @cmpxchgStrong(T: u32, ptr, expected_value: 1, new_value: 2, success_order: .seq_cst, fail_order: .monotonic);
        \\    _ = @divExact(x, 2);
        \\    _ = @as(u32, @intCast(x));
        \\    @panic("unreachable");
        \\}
        \\
    , try inlaid(&w, file, text, .{}));
    // Single-argument builtins are governed only by exclude_single_argument
    try testing.expectEqualStrings(
        \\fn f(buf: []u8, data: []const u8, ptr: *u32, x: u64) void {
        \\    @memcpy(dest: buf, source: data);
        \\    _ = @cmpxchgStrong(T: u32, ptr, expected_value: 1, new_value: 2, success_order: .seq_cst, fail_order: .monotonic);
        \\    _ = @divExact(x, 2);
        \\    _ = @as(u32, @intCast(int: x));
        \\    @panic(message: "unreachable");
        \\}
        \\
    , try inlaid(&w, file, text, .{ .exclude_single_argument = false }));
}

test "inlay hints: calls with a single argument, including method calls" {
    const text =
        \\const S = struct {
        \\    v: u32,
        \\    fn set(self: *S, value: u32) void {
        \\        self.v = value;
        \\    }
        \\    fn pair(self: *S, a: u32, b: u32) void {
        \\        _ = .{ self, a, b };
        \\    }
        \\};
        \\fn one(n: u32) void {
        \\    _ = n;
        \\}
        \\fn f(s: *S) void {
        \\    one(1);
        \\    s.set(2);
        \\    S.set(s, 3);
        \\    s.pair(4, 5);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const calls = struct {
        fn of(annotated: []const u8) []const u8 {
            return annotated[std.mem.indexOf(u8, annotated, "fn f(").?..];
        }
    }.of;
    // By the number of arguments as written: a method call left with one argument after dropping
    // the receiver gets no hint either, while `S.set(s, 3)`, called through the type, has two
    // arguments
    try testing.expectEqualStrings(
        \\fn f(s: *S) void {
        \\    one(1);
        \\    s.set(2);
        \\    S.set(self: s, value: 3);
        \\    s.pair(a: 4, b: 5);
        \\}
        \\
    , calls(try inlaid(&w, file, text, .{})));
    try testing.expectEqualStrings(
        \\fn f(s: *S) void {
        \\    one(n: 1);
        \\    s.set(value: 2);
        \\    S.set(self: s, value: 3);
        \\    s.pair(a: 4, b: 5);
        \\}
        \\
    , calls(try inlaid(&w, file, text, .{ .exclude_single_argument = false })));
}

test "inlay hints: redundant parameter names look through address-of, deref, unwrap and try" {
    const text =
        \\const S = struct { buf: u32, len: ?u32 };
        \\fn take(buf: *const u32, len: u32) void {
        \\    _ = .{ buf, len };
        \\}
        \\fn f(s: *S, buf: *u32, len: anyerror!u32, opt: ?*const u32) !void {
        \\    take(buf, try len);
        \\    take(&s.buf, s.len.?);
        \\    take(&s.*.buf, (try len) + 1);
        \\    take(opt.?, -%(try len));
        \\    take(buf, s.len orelse 0);
        \\}
        \\fn g(buf: **u32, len: *const ?u32) void {
        \\    take(buf.*, len.*.?);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    // Several levels can be looked through; `+`, `-%` and `orelse` produce new values and get hints
    // as usual
    try testing.expectEqualStrings(
        \\const S = struct { buf: u32, len: ?u32 };
        \\fn take(buf: *const u32, len: u32) void {
        \\    _ = .{ buf, len };
        \\}
        \\fn f(s: *S, buf: *u32, len: anyerror!u32, opt: ?*const u32) !void {
        \\    take(buf, try len);
        \\    take(&s.buf, s.len.?);
        \\    take(&s.*.buf, len: (try len) + 1);
        \\    take(buf: opt.?, len: -%(try len));
        \\    take(buf, len: s.len orelse 0);
        \\}
        \\fn g(buf: **u32, len: *const ?u32) void {
        \\    take(buf.*, len.*.?);
        \\}
        \\
    , try inlaid(&w, file, text, .{ .types = false }));
}

test "callsite seeding can be switched off" {
    const text =
        \\fn max(comptime T: type, a: T, b: T) T {
        \\    const bigger = if (a > b) a else b;
        \\    return bigger;
        \\}
        \\fn run() void {
        \\    _ = max(u32, 1, 2);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var seeding: std.atomic.Value(bool) = .init(false);
    w.env.callsite_seeding = &seeding;
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "bigger =").?), &.{}, .list) orelse return error.NoHover;
    // Not inferred from a call-site instance: shows the abstract type, without "inferred from"
    try testing.expectEqualStrings("```zig\nconst bigger: T\n```", info.text);
}

test "member completion on values lists function aliases as methods" {
    const text =
        \\const Arch = enum {
        \\    x86,
        \\    arm,
        \\    pub fn isArm(a: Arch) bool { return a == .arm; }
        \\    pub const isARM = isArm;
        \\    pub const count = 2;
        \\};
        \\fn f(a: Arch) bool { return a.<|>; }
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    // The function alias `isARM` can be called as a method; the value constant `count` is not
    // listed
    try testing.expectEqualStrings("isArm isARM", try std.mem.join(w.arena.allocator(), " ", labels.items));
}

test "completion in a branch inactive for the first call site uses a call site where it is active" {
    const text =
        \\const Rgb = struct { r: u8 };
        \\const Rgba = struct { r: u8, a: u8 };
        \\fn opaqueOf(comptime T: type, v: T) T {
        \\    var res = v;
        \\    if (@hasField(T, "a")) {
        \\        res.<|> = 255;
        \\    }
        \\    return res;
        \\}
        \\fn run() void {
        \\    _ = opaqueOf(Rgb, .{ .r = 0 });
        \\    _ = opaqueOf(Rgba, .{ .r = 0, .a = 0 });
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    // The branch is not active for the first call site (Rgb): the second call site (Rgba) is used
    try testing.expectEqualStrings("r a", try std.mem.join(w.arena.allocator(), " ", labels.items));
}

test "completion in a switch prong on @typeInfo uses a call site where the prong is taken" {
    // For the first call site (a struct), the `.pointer` prong is not executed; completion used to
    // still use its instance, listing the struct's fields
    const text =
        \\const Top = struct { name: []const u8 };
        \\fn measure(a: anytype) usize {
        \\    switch (@typeInfo(@TypeOf(a))) {
        \\        .@"struct" => return 1,
        \\        .pointer => return a.<|>,
        \\        else => return 0,
        \\    }
        \\}
        \\fn run() void {
        \\    _ = measure(Top{ .name = "x" });
        \\    const s: []const u8 = "abc";
        \\    _ = measure(s);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    try testing.expectEqualStrings("len ptr", try std.mem.join(w.arena.allocator(), " ", labels.items));
}

/// Completes at `<|>` in `text` and returns the labels joined by spaces
fn completionLabels(text: []const u8) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(testing.allocator, it.label);
    defer labels.deinit(testing.allocator);
    return testing.allocator.dupe(u8, try std.mem.join(w.arena.allocator(), " ", labels.items));
}

test "callsite seeding skips calls in branches the caller instance does not compile" {
    // For the first instance (Input), the call to `ensure` is in a branch that is not executed: an
    // Input instance used to still be inferred from it, completing fields that only Input has
    const labels = try completionLabels(
        \\const Input = struct {
        \\    pub const kind = .input;
        \\};
        \\const Derived = struct {
        \\    pub const kind = .derived;
        \\};
        \\fn Slot(comptime Q: type) type {
        \\    return switch (Q.kind) {
        \\        .input => struct { is_set: bool },
        \\        .derived => struct { memo: ?u32 },
        \\        else => unreachable,
        \\    };
        \\}
        \\fn get(comptime Q: type) void {
        \\    switch (Q.kind) {
        \\        .input => {},
        \\        .derived => ensure(Q),
        \\        else => unreachable,
        \\    }
        \\}
        \\fn ensure(comptime Q: type) void {
        \\    var slot: Slot(Q) = undefined;
        \\    _ = slot.<|>;
        \\}
        \\fn run() void {
        \\    get(Input);
        \\    get(Derived);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("memo", labels);
}

test "completion omits the _ of a non-exhaustive enum" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "const NE = enum(u8) { a, b, _ };\ntest {\n    const ne: NE = .<|>;\n    _ = ne;\n}\n", "a b" },
        .{ "const NE = enum(u8) { a, b, _ };\ntest {\n    _ = NE.<|>;\n}\n", "a b" },
        .{ "const NE = enum(u8) { a, b, _ };\nfn f(ne: NE) void {\n    switch (ne) {\n        .<|>\n    }\n}\n", "a b" },
        // `@"_"` is an ordinary field
        .{ "const Q = enum { a, @\"_\" };\ntest {\n    const q: Q = .<|>;\n    _ = q;\n}\n", "a @\"_\"" },
    };
    for (cases) |c| {
        const labels = try completionLabels(c[0]);
        defer testing.allocator.free(labels);
        try testing.expectEqualStrings(c[1], labels);
    }
}

test "callsite seeding falls back to calls in branches no instance of the caller compiles" {
    // The only call is in a branch that no instance of the caller compiles: skipping such calls
    // used to leave no instance, so completion was empty
    const labels = try completionLabels(
        \\const Point = struct { x: u32, y: u32 };
        \\fn read(p: anytype) u32 {
        \\    return p.<|>;
        \\}
        \\fn outer(comptime T: type, v: T) u32 {
        \\    if (@hasField(T, "z")) return read(v);
        \\    return 0;
        \\}
        \\test {
        \\    _ = outer(Point, .{ .x = 1, .y = 2 });
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("x y", labels);
}

test "callsite seeding picks an instance in which the expression at the cursor has a type" {
    // For the first call site (Input), `Q.Memo` does not exist and the type of `m` is unknown:
    // completion used to be empty
    const labels = try completionLabels(
        \\const Input = struct {};
        \\const Derived = struct {
        \\    pub const Memo = struct { evicted: bool };
        \\};
        \\fn last(comptime Q: type) void {
        \\    const m: Q.Memo = undefined;
        \\    _ = m.<|>;
        \\}
        \\fn run() void {
        \\    last(Input);
        \\    last(Derived);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("evicted", labels);
}

test "callsite seeding skips instances for which a guard before the cursor fires" {
    // `if (!@hasDecl(Q, "fallback")) unreachable;` is taken for the first call site (A), so the
    // code after it is not compiled: completion used to still use A
    const labels = try completionLabels(
        \\const A = struct {};
        \\const B = struct {
        \\    pub fn fallback() u32 {
        \\        return 1;
        \\    }
        \\};
        \\fn onCycle(comptime Q: type) u32 {
        \\    if (!@hasDecl(Q, "fallback")) unreachable;
        \\    return Q.<|>();
        \\}
        \\fn run() void {
        \\    _ = onCycle(A);
        \\    _ = onCycle(B);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("fallback", labels);
}

test "code after a statement that comptime makes noreturn is inactive" {
    const text =
        \\const linux_only = true;
        \\fn f(x: u32) u32 {
        \\    if (linux_only) return 1;
        \\    const y = x + 2;
        \\    return y;
        \\}
        \\fn g(x: u32) u32 {
        \\    if (x > 3) return 1;
        \\    return x;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const ranges = try inactive.ranges(&r, file);
    // Code after a runtime condition is not inactive code
    try testing.expectEqual(1, ranges.len);
    try testing.expectEqualStrings("const y = x + 2;\n    return y;", text[ranges[0].start..ranges[0].end]);
}

test "the right side of a comptime short-circuited and / or is inactive" {
    const text =
        \\const debug = false;
        \\fn f(x: bool) bool {
        \\    return debug and x;
        \\}
        \\fn g(x: bool) bool {
        \\    return x and debug;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const ranges = try inactive.ranges(&r, file);
    // When the left side is a runtime value, the right side is compiled as usual
    try testing.expectEqual(1, ranges.len);
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "x;").?)), ranges[0].start);
}

test "callsite seeding uses the caller instance with the matching comptime type argument" {
    // `A.step` and `B.step` are both called through `Impl.step(ctx)` in `run`; `run` is called with
    // B first, but inside A.step, A's instance must still be used
    const labels = try completionLabels(
        \\const CA = struct { a_field: u32 };
        \\const CB = struct { b_field: u32 };
        \\const A = struct {
        \\    pub fn step(c: anytype) u32 {
        \\        return c.<|>;
        \\    }
        \\};
        \\const B = struct {
        \\    pub fn step(c: anytype) u32 {
        \\        _ = c;
        \\        return 0;
        \\    }
        \\};
        \\fn run(comptime Impl: type, ctx: anytype) u32 {
        \\    return Impl.step(ctx);
        \\}
        \\fn main() void {
        \\    var ca: CA = .{ .a_field = 1 };
        \\    var cb: CB = .{ .b_field = 2 };
        \\    _ = run(B, &cb);
        \\    _ = run(A, &ca);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("a_field", labels);
}

test "via a comptime type parameter dispatch uses the real caller instance" {
    const text =
        \\const Foo = struct {
        \\    fn hello(_: Foo) void {}
        \\};
        \\const Bar = struct {
        \\    fn hello(_: Bar) void {}
        \\};
        \\const A = struct {
        \\    fn name(x: anytype) void {
        \\        x.hello();
        \\    }
        \\};
        \\const B = struct {
        \\    fn name(x: anytype) void {
        \\        _ = x;
        \\    }
        \\};
        \\fn caller(comptime P: type, y: anytype) void {
        \\    P.name(y);
        \\}
        \\pub fn main() void {
        \\    caller(B, Bar{});
        \\    caller(A, Foo{});
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at_x: u32 = @intCast(std.mem.indexOf(u8, text, "        x.hello").? + "        ".len);
    const at_hello: u32 = @intCast(std.mem.indexOf(u8, text, "        x.hello").? + "        x.".len);

    const x = (try hover.hover(&r, file, at_x, &.{}, .list)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nx: Foo\n```\n\ninferred from the call at main.zig:18", x.text);
    const hello = (try hover.hover(&r, file, at_hello, &.{}, .list)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nfn hello(_: Foo) void\n```\n\ninferred from the call at main.zig:18", hello.text);
    const t = (try definition.definition(&r, file, at_hello)) orelse return error.NoTarget;
    try testing.expect(std.mem.startsWith(u8, text[t.start..], "hello(_: Foo)"));
}

test "via a comptime type parameter dispatch without a real instance stays abstract" {
    // `caller(A, ..)` does not exist: the compiler does not generate an instance of `A.name`, so
    // the instance of `caller(B, ..)` must not be borrowed
    const text =
        \\const Foo = struct {
        \\    fn hello(_: Foo) void {}
        \\};
        \\const Bar = struct {
        \\    fn hello(_: Bar) void {}
        \\};
        \\const A = struct {
        \\    fn name(x: anytype) void {
        \\        x.hello();
        \\    }
        \\};
        \\const B = struct {
        \\    fn name(x: anytype) void {
        \\        _ = x;
        \\    }
        \\};
        \\fn caller(comptime P: type, y: anytype) void {
        \\    P.name(y);
        \\}
        \\pub fn main() void {
        \\    caller(B, Bar{});
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const at_x: u32 = @intCast(std.mem.indexOf(u8, text, "        x.hello").? + "        ".len);
    const at_hello: u32 = at_x + @as(u32, @intCast("x.".len));

    const x = (try hover.hover(&r, file, at_x, &.{}, .list)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nx: unknown\n```", x.text);
    try testing.expect(try hover.hover(&r, file, at_hello, &.{}, .list) == null);
    try testing.expect(try definition.definition(&r, file, at_hello) == null);
}

test "callsite seeding follows a container type passed as a comptime argument to the call that dispatches to it" {
    // The file of the dispatch site (`Q.compute(ctx)` in engine.zig) does not import the file of
    // the target: following the import chain used to find no call site, and the type of `ctx` was
    // unknown
    const queries_text =
        \\pub const Item = struct {
        \\    pub fn compute(ctx: anytype) u32 {
        \\        return ctx.<|>;
        \\    }
        \\};
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const engine_file = (try w.add("/p/engine.zig",
        \\pub fn Engine(comptime Ctx: type) type {
        \\    return struct {
        \\        pub fn get(ctx: *Ctx, comptime Q: type) u32 {
        \\            return inner(ctx, Q);
        \\        }
        \\        fn inner(ctx: *Ctx, comptime Q: type) u32 {
        \\            return Q.compute(ctx);
        \\        }
        \\    };
        \\}
        \\
    )).file;
    const added = try w.add("/p/queries.zig", queries_text);
    const main = (try w.add("/p/main.zig",
        \\const Engine = @import("engine.zig").Engine;
        \\const queries = @import("queries.zig");
        \\const Ctx = struct { n: u32 };
        \\const Db = Engine(Ctx);
        \\fn run(ctx: *Ctx) u32 {
        \\    return Db.get(ctx, queries.Item);
        \\}
        \\
    )).file;
    try w.setGraph(null, &.{.{ .root = main, .imports = &.{} }}, &.{
        .{ .file = engine_file, .module = 0, .compile = 0 },
        .{ .file = added.file, .module = 0, .compile = 0 },
        .{ .file = main, .module = 0, .compile = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    try testing.expectEqualStrings("n", try std.mem.join(w.arena.allocator(), " ", labels.items));
}

test "inside an inline for over a list of types, features use one iteration" {
    // The loop variable is abstract in inference (its type differs in each iteration): completion
    // used to be empty and hover could not compute the type
    const text =
        \\const A = struct {
        \\    pub fn name() u32 {
        \\        return 1;
        \\    }
        \\};
        \\const B = struct {
        \\    pub fn name() u32 {
        \\        return 2;
        \\    }
        \\};
        \\fn f() u32 {
        \\    var sum: u32 = 0;
        \\    inline for (.{ A, B }) |T| {
        \\        const v = T.name();
        \\        sum += T.<|>();
        \\        sum += v;
        \\    }
        \\    return sum;
        \\}
        \\
    ;
    const labels = try completionLabels(text);
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("name", labels);

    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const plain = try std.mem.replaceOwned(u8, w.arena.allocator(), text, "<|>", "");
    const info = (try hover.hover(&r, added.file, @intCast(std.mem.indexOf(u8, plain, "v = ").?), &.{}, .list)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst v: u32\n```\n\ninferred from iteration 1 of the loop at main.zig:13", info.text);
}

test "callsite seeding uses an iteration of an inline for over types that the call is in" {
    // The call is inside an `inline for` over a list of types, and the argument is the abstract
    // loop variable: the instance of `get` used to be unresolvable
    const labels = try completionLabels(
        \\const A = struct { x: u32 };
        \\fn get(comptime T: type) void {
        \\    var v: T = undefined;
        \\    _ = v.<|>;
        \\}
        \\fn all() void {
        \\    inline for (.{A}) |T| get(T);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("x", labels);
}

/// `inline for (.{ E0, E1, ..., A }) |T|`, where only `A` (iteration `empty + 1`) has `run`
fn manyTypesLoop(comptime empty: usize) []const u8 {
    @setEvalBranchQuota(100_000);
    var list: []const u8 = "";
    var decls: []const u8 = "";
    for (0..empty) |i| {
        decls = decls ++ std.fmt.comptimePrint("const E{d} = struct {{}};\n", .{i});
        list = list ++ std.fmt.comptimePrint("E{d}, ", .{i});
    }
    return decls ++
        \\const A = struct {
        \\    pub fn run() void {}
        \\};
        \\fn all() void {
        \\
    ++ "    inline for (.{ " ++ list ++ "A }) |T| {\n" ++
        \\        if (@hasDecl(T, "run")) T.run();
        \\    }
        \\}
        \\
    ;
}

test "features inside an inline for over types use iterations past the first 64" {
    // Only the first 64 iterations used to be tried: `A`, which comes after them, could not be
    // resolved
    const text = comptime manyTypesLoop(80);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const target = try definition.definition(&r, file, @intCast(std.mem.indexOf(u8, text, "T.run()").? + 2)) orelse return error.NoDefinition;
    try testing.expectEqual(std.mem.indexOf(u8, text, "run() void").?, target.start);
}

test "an inline for over a list that is a parameter of the enclosing generic function uses the call site's list" {
    const labels = try completionLabels(
        \\fn Engine(comptime queries: []const type) type {
        \\    return struct {
        \\        pub fn reset() void {
        \\            inline for (queries) |Q| {
        \\                _ = Q.<|>;
        \\            }
        \\        }
        \\    };
        \\}
        \\const A = struct {
        \\    pub const id = 1;
        \\};
        \\const Db = Engine(&.{A});
        \\fn main() void {
        \\    Db.reset();
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("id", labels);
}

test "an iteration of a loop over types also gives the other captures of the loop their values" {
    // Only the loop variable holding a type used to get a value: the index `i` had no value, so the
    // element `tables[i]` could not be resolved; the plain loop nested inside does not affect the
    // choice
    const labels = try completionLabels(
        \\const A = struct {};
        \\const B = struct {};
        \\const tables = .{ .{ .a_field = @as(u32, 0) }, .{ .b_field = @as(u32, 0) } };
        \\fn f() void {
        \\    inline for (.{ A, B }, 0..) |T, i| {
        \\        _ = T;
        \\        for (0..2) |_| {
        \\            _ = tables[i].<|>;
        \\        }
        \\    }
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("a_field", labels);
}

test "callsite seeding uses an iteration of a comptime for over types" {
    // A plain `for` (not `inline for`) over a list of types in a comptime block is also inferred
    // per iteration
    const labels = try completionLabels(
        \\const A = struct {
        \\    pub const id = 1;
        \\};
        \\fn check(comptime Q: type) void {
        \\    _ = Q.<|>;
        \\}
        \\comptime {
        \\    for (.{A}) |Q| check(Q);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("id", labels);
}

test "inside an inline for over a tuple whose items have different types, features use one iteration" {
    // The items have different types (arrays of different lengths, strings), so merged inference
    // cannot compute the type of the loop variable: completion used to be empty
    const by_array = try completionLabels(
        \\const Case = struct { base: u32, expected: ?u32 };
        \\const short = [_]Case{.{ .base = 1, .expected = null }};
        \\const long = [_]Case{ .{ .base = 1, .expected = 2 }, .{ .base = 3, .expected = null } };
        \\test {
        \\    inline for (.{ &short, &long }) |cases| {
        \\        for (cases) |c| {
        \\            _ = c.<|>;
        \\        }
        \\    }
        \\}
        \\
    );
    defer testing.allocator.free(by_array);
    try testing.expectEqualStrings("base expected", by_array);
    // The tuple's values are known only at runtime, while the types of its items are comptime-known
    const by_name = try completionLabels(
        \\const Flag = enum {
        \\    on,
        \\    off,
        \\    pub fn toBool(f: Flag) bool {
        \\        return f == .on;
        \\    }
        \\};
        \\fn count(strip: Flag, fuzz: Flag) u32 {
        \\    const flags = .{ .{ "strip", strip }, .{ "single-threaded", fuzz } };
        \\    var n: u32 = 0;
        \\    inline for (flags) |f| {
        \\        if (f[1].<|>) n += 1;
        \\    }
        \\    return n;
        \\}
        \\
    );
    defer testing.allocator.free(by_name);
    try testing.expectEqualStrings("toBool", by_name);
}

test "callsite seeding tries every instance for a branch only rare instances compile" {
    // Only the 10th instance has `extra`, and the caller is itself in a generic function: only the
    // caller's first 8 instances used to be tried, leaving completion empty
    const labels = try completionLabels(
        \\const A0 = struct {
        \\    pub const id = 0;
        \\};
        \\const A1 = struct {
        \\    pub const id = 1;
        \\};
        \\const A2 = struct {
        \\    pub const id = 2;
        \\};
        \\const A3 = struct {
        \\    pub const id = 3;
        \\};
        \\const A4 = struct {
        \\    pub const id = 4;
        \\};
        \\const A5 = struct {
        \\    pub const id = 5;
        \\};
        \\const A6 = struct {
        \\    pub const id = 6;
        \\};
        \\const A7 = struct {
        \\    pub const id = 7;
        \\};
        \\const A8 = struct {
        \\    pub const id = 8;
        \\};
        \\const Z = struct {
        \\    pub const id = 9;
        \\    pub fn extra() u32 {
        \\        return 1;
        \\    }
        \\};
        \\fn get(comptime Q: type) u32 {
        \\    if (@hasDecl(Q, "extra")) return Q.<|>;
        \\    return Q.id;
        \\}
        \\fn outer(comptime Q: type) u32 {
        \\    return get(Q);
        \\}
        \\test {
        \\    _ = outer(A0);
        \\    _ = outer(A1);
        \\    _ = outer(A2);
        \\    _ = outer(A3);
        \\    _ = outer(A4);
        \\    _ = outer(A5);
        \\    _ = outer(A6);
        \\    _ = outer(A7);
        \\    _ = outer(A8);
        \\    _ = outer(Z);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("id extra", labels);
}

test "an inline switch prong over several tags captures the payload of the operand's tag" {
    // The items of the prong have different payload types (`std.lang.Type.Struct` and `Union`), and
    // resolving them by peer type used to give no type for the capture
    const text =
        \\const S = struct { a: u32, b: u8 };
        \\fn count(comptime T: type) usize {
        \\    return switch (@typeInfo(T)) {
        \\        inline .@"struct", .@"union" => |info| info.<|>,
        \\        else => 0,
        \\    };
        \\}
        \\test {
        \\    _ = count(S);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    var found = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "field_types")) found = true;
    }
    try testing.expect(found);
}

test "completion through single pointers to arrays, tuples and slices" {
    // After dereferencing a single pointer, the namespace used to be looked up directly: completion
    // was empty for pointers to arrays or tuples (such as `.len` of a string constant)
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "fn f() void {\n    const prefix = \"file://\";\n    _ = prefix.<|>;\n}\n", "len ptr" },
        .{ "fn f() void {\n    const t = .{ 1, 2 };\n    const p = &t;\n    _ = p.<|>;\n}\n", "@\"0\" @\"1\" len" },
        .{ "fn f(s: *[]const u8) void {\n    _ = s.<|>;\n}\n", "len ptr" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", c[0]);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
        var labels: std.ArrayList([]const u8) = .empty;
        for (items) |it| try labels.append(w.arena.allocator(), it.label);
        try testing.expectEqualStrings(c[1], try std.mem.join(w.arena.allocator(), " ", labels.items));
    }
}

test "member completion on an enum value lists its functions but not its tags" {
    // Tags used to be listed after `.` on an enum value, although Zig accesses them only through
    // the type
    const color =
        \\const Color = enum {
        \\    red,
        \\    green,
        \\    pub fn isRed(self: Color) bool { return self == .red; }
        \\};
        \\
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "fn f(color: Color) void { _ = color.<|>; }", "isRed" },
        .{ "fn f(color: *const Color) void { _ = color.<|>; }", "isRed" },
        // Tags are accessed through the type
        .{ "fn f() void { _ = Color.<|>; }", "isRed red green" },
        // The fields of a union value are its payloads
        .{ "const U = union(enum) { a: u32, b: bool, pub fn isA(self: U) bool { return self == .a; } };\nfn f(u: U) void { _ = u.<|>; }", "a b isA" },
    };
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator, "{s}{s}\n", .{ color, c[0] });
        defer testing.allocator.free(source);
        const got = try completionLabels(source);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("case: {s}\n", .{c[0]});
            return err;
        };
    }
}

test "member completion on values lists the functions that can be called on them as methods" {
    // Every function of the type used to be listed, including those the compiler rejects there:
    // ones whose first parameter does not take the value (`v.init()`), and ones receiving `*T` on a
    // value that cannot be modified
    const types =
        \\const S = struct {
        \\    x: u8 = 0,
        \\    pub fn byVal(self: S) void { _ = self; }
        \\    pub fn byPtr(self: *S) void { _ = self; }
        \\    pub fn byConstPtr(self: *const S) void { _ = self; }
        \\    pub fn byOpt(self: ?S) void { _ = self; }
        \\    pub fn byOptPtr(self: ?*S) void { _ = self; }
        \\    pub fn byErr(self: anyerror!S) void { _ = self catch {}; }
        \\    pub fn byAny(self: anytype) void { _ = self; }
        \\    pub fn init() S { return .{}; }
        \\    pub fn other(n: u8) void { _ = n; }
        \\    pub fn bySlice(self: []S) void { _ = self; }
        \\    pub const reset = byPtr;
        \\};
        \\const Outer = struct { inner: S = .{} };
        \\fn make() S { return .{}; }
        \\fn G(comptime T: type) type {
        \\    return struct {
        \\        v: T,
        \\        const Self = @This();
        \\        pub fn get(self: Self) T { return self.v; }
        \\        pub fn set(self: *Self, v: T) void { self.v = v; }
        \\        pub fn of(v: T) Self { return .{ .v = v }; }
        \\    };
        \\}
        \\
    ;
    const mutable = "x byVal byPtr byConstPtr byOpt byOptPtr byErr byAny reset";
    const immutable = "x byVal byConstPtr byOpt byErr byAny";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "fn f() void { var v: S = .{}; _ = &v; _ = v.<|>; }", mutable },
        .{ "fn f() void { const v: S = .{}; _ = v.<|>; }", immutable },
        // Parameters, value captures, and temporaries cannot be modified
        .{ "fn f(v: S) void { _ = v.<|>; }", immutable },
        .{ "fn f(xs: []S) void { for (xs) |x| { _ = x.<|>; } }", immutable },
        .{ "fn f() void { _ = make().<|>; }", immutable },
        // Through a pointer, it depends on the pointer
        .{ "fn f(p: *S) void { _ = p.<|>; }", mutable },
        .{ "fn f(p: *const S) void { _ = p.<|>; }", immutable },
        .{ "fn f(xs: []S) void { for (xs) |*x| { _ = x.<|>; } }", mutable },
        .{ "fn f(xs: []S) void { _ = xs[0].<|>; }", mutable },
        .{ "fn f(xs: []const S) void { _ = xs[0].<|>; }", immutable },
        // Members and payloads are parts of the value holding them
        .{ "fn f() void { var o: Outer = .{}; _ = &o; _ = o.inner.<|>; }", mutable },
        .{ "fn f() void { const o: Outer = .{}; _ = o.inner.<|>; }", immutable },
        .{ "fn f() void { var o: Outer = .{}; _ = &o; _ = @field(o, \"inner\").<|>; }", mutable },
        .{ "fn f() void { var o: ?S = null; _ = &o; _ = o.?.<|>; }", mutable },
        // Methods of an instance of a generic type
        .{ "fn f() void { const g: G(u8) = .of(1); _ = g.<|>; }", "v get" },
        .{ "fn f() void { var g: G(u8) = .of(1); _ = &g; _ = g.<|>; }", "v get set" },
    };
    for (cases) |c| {
        const source = try std.fmt.allocPrint(testing.allocator, "{s}{s}\n", .{ types, c[0] });
        defer testing.allocator.free(source);
        const got = try completionLabels(source);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("case: {s}\n", .{c[0]});
            return err;
        };
    }
}

test "goto declaration on names that declare themselves: error set members and anonymous fields" {
    const text =
        \\const Error = error{ Timeout, Closed };
        \\const Point = struct { x: i32 };
        \\fn f(opts: anytype) void {
        \\    _ = opts;
        \\}
        \\fn g() void {
        \\    f(.{ .verbose = true });
        \\    const table = .{ .first = 1, .second = 2 };
        \\    const p: Point = .{ .x = 0 };
        \\    _ = .{ table, p };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, usize, []const u8 }{
        // Members of error sets and field names of anonymous initializers: they are their own
        // declarations
        .{ "Timeout", 0, "Timeout" },
        .{ "Closed", 0, "Closed" },
        .{ ".verbose", 1, "verbose" },
        .{ ".second", 1, "second" },
        // With a result type: goes to the field's declaration
        .{ ".x = 0", 1, "x: i32" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).? + c[1];
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[2])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..@min(text.len, t.start + 20)] });
            return err;
        };
    }
}

test "goto declaration of tagged union fields accessed through the type or an error union result" {
    const text =
        \\const Value = union(enum) { null_val: void, int: i64 };
        \\const Error = error{Bad};
        \\fn parse(n: u8) Error!Value {
        \\    if (n == 0) return .null_val;
        \\    return .{ .int = n };
        \\}
        \\test {
        \\    const v = Value.null_val;
        \\    _ = v;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ([_][]const u8{ "null_val;\n    return", "null_val;\n    _" }, 0..) |needle, i| {
        const at = std.mem.indexOf(u8, text, needle).? + 1;
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        try testing.expect(std.mem.startsWith(u8, text[t.start..], "null_val: void"));
    }
}

test "goto declaration of members that exist only in other target branches" {
    const text =
        \\const os: enum { linux, macos } = .linux;
        \\const linux_ns = struct {
        \\    pub const SO = struct {
        \\        pub const REUSEADDR = 2;
        \\    };
        \\    pub const termios = extern struct {
        \\        cflag: tc_cflag_t,
        \\    };
        \\    pub const tc_cflag_t = packed struct(u32) {
        \\        CREAD: bool = false,
        \\        _: u31 = 0,
        \\    };
        \\};
        \\const c_ns = struct {
        \\    pub const termios = switch (os) {
        \\        .linux => linux_ns.termios,
        \\        .macos => extern struct {
        \\            cflag: tc_cflag_t,
        \\        },
        \\    };
        \\    pub const tc_cflag_t = switch (os) {
        \\        .linux => linux_ns.tc_cflag_t,
        \\        .macos => packed struct(u64) {
        \\            CCTS_OFLOW: bool = false,
        \\            _: u63 = 0,
        \\        },
        \\    };
        \\    pub const SO = switch (os) {
        \\        .linux => struct {
        \\            pub const REUSEADDR = 2;
        \\        },
        \\        .macos => struct {
        \\            pub const REUSEPORT_LB = 0x10000;
        \\        },
        \\    };
        \\    pub const EVFILT = switch (os) {
        \\        .macos => struct {
        \\            pub const READ = -1;
        \\        },
        \\        else => void,
        \\    };
        \\};
        \\const system = switch (os) {
        \\    .linux => linux_ns,
        \\    .macos => c_ns,
        \\};
        \\const SO = system.SO;
        \\const posix_ns = struct {
        \\    pub const termios = system.termios;
        \\    pub fn tcgetattr(fd: u32) error{NotATerminal}!termios {
        \\        _ = fd;
        \\        return undefined;
        \\    }
        \\};
        \\const posix_impl = struct {
        \\    pub const State = struct {
        \\        fd: u32 = 0,
        \\        pub fn init() State {
        \\            return .{};
        \\        }
        \\    };
        \\};
        \\const windows_impl = struct {
        \\    pub const State = struct {
        \\        handle: u32 = 0,
        \\        pub fn init() State {
        \\            return .{};
        \\        }
        \\    };
        \\};
        \\const platform = if (os == .macos) windows_impl else posix_impl;
        \\const Terminal = struct {
        \\    state: platform.State,
        \\};
        \\fn f(t: *Terminal) void {
        \\    _ = SO.REUSEPORT_LB;
        \\    _ = system.EVFILT.READ;
        \\    _ = t.state.handle;
        \\    var s = platform.State.init();
        \\    _ = s.handle;
        \\    _ = platform.State.init().handle;
        \\    _ = t.state.fd;
        \\}
        \\fn g() !void {
        \\    var settings = try posix_ns.tcgetattr(0);
        \\    settings.cflag.CCTS_OFLOW = true;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        // The alias `system.SO` and nested switches
        .{ "REUSEPORT_LB;", "REUSEPORT_LB = 0x10000" },
        // EVFILT is void under the current configuration
        .{ "READ;", "READ = -1" },
        // Field types, `init()` of a local variable, call results
        .{ "handle;\n    var", "handle: u32" },
        .{ "handle;\n    _ = platform", "handle: u32" },
        .{ "handle;\n    _ = t", "handle: u32" },
        // Members that exist under the current configuration
        .{ "fd;\n}", "fd: u32" },
        // The function's return type is selected by target, and the field's type again by target
        .{ "CCTS_OFLOW = true", "CCTS_OFLOW: bool = false" },
    };
    for (cases, 0..) |c, i| {
        const at = std.mem.indexOf(u8, text, c[0]).?;
        const t = try definition.declaration(&r, file, @intCast(at)) orelse {
            std.debug.print("case {d}: no target\n", .{i});
            return error.NoTarget;
        };
        testing.expect(std.mem.startsWith(u8, text[t.start..], c[1])) catch |err| {
            std.debug.print("case {d}: target `{s}`\n", .{ i, text[t.start..@min(text.len, t.start + 24)] });
            return err;
        };
    }
}

fn seedFor(w: *World, file: FileId, name: []const u8) !?seed.Seed {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    const tree = try r.itemTree(file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.name) |n| if (std.mem.eql(u8, n, name)) break @intCast(i);
    } else return error.NoItem;
    const chosen = try seed.find(&r, file, item);
    _ = try ctx.get(seed.Instances, .{ .owner = try r.ownerKey(file, item), .depth = seed.max_depth });
    _ = try seed.allInstances(&r, file, item);
    return chosen;
}

test "recursive chosen and negative seeds survive prefix edits without executing search" {
    const text =
        \\fn leaf(x: anytype) @TypeOf(x) { return x; }
        \\fn mid(x: anytype) @TypeOf(x) {
        \\    const Wrap = struct { value: @TypeOf(x) };
        \\    const wrapper: Wrap = .{ .value = x };
        \\    return leaf(wrapper.value);
        \\}
        \\fn absent(x: anytype) void { _ = x; }
        \\fn cold(x: anytype) void { absent(x); }
        \\fn run() void { _ = mid(@as(u16, 1)); }
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const chosen = (try seedFor(&w, file, "leaf")).?;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "leaf(wrapper.value)").?)), chosen.offset);
    try testing.expectEqual(null, try seedFor(&w, file, "absent"));
    const counters = .{
        w.db.executions(seed.Query),
        w.db.executions(seed.Instances),
        w.db.executions(seed.Candidates),
        w.db.executions(@import("../ide_db/search.zig").ProjectImporters),
    };
    try testing.expect(counters[0] >= 4);
    for ([_][]const u8{ "// prefix\n" ++ text, text, "// another prefix\n" ++ text, text }) |updated| {
        _ = try w.add("/p/main.zig", updated);
        const current = (try seedFor(&w, file, "leaf")).?;
        try testing.expectEqual(chosen.inst, current.inst);
        try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, updated, "leaf(wrapper.value)").?)), current.offset);
        try testing.expectEqual(null, try seedFor(&w, file, "absent"));
        try testing.expectEqual(counters[0], w.db.executions(seed.Query));
        try testing.expectEqual(counters[1], w.db.executions(seed.Instances));
        try testing.expectEqual(counters[2], w.db.executions(seed.Candidates));
        try testing.expectEqual(counters[3], w.db.executions(@import("../ide_db/search.zig").ProjectImporters));
    }
}

test "seed search skips callers whose calls resolve to other functions of the same name" {
    // `format` mentions print but calls Writer.print: it cannot call the target in any instance, so
    // its own call sites are not searched for
    const text =
        \\pub fn print(comptime fmt: []const u8, args: anytype) void {
        \\    _ = fmt;
        \\    _ = args;
        \\}
        \\const Writer = struct {
        \\    pub fn print(w: Writer, comptime fmt: []const u8) void {
        \\        _ = w;
        \\        _ = fmt;
        \\    }
        \\};
        \\fn format(comptime T: type, w: Writer) void {
        \\    w.print("{}");
        \\    _ = T;
        \\}
        \\fn useFormat() void {
        \\    format(u8, .{});
        \\}
        \\fn main() void {
        \\    print("{}", .{@as(u8, 1)});
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const chosen = (try seedFor(&w, file, "print")).?;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "print(\"{}\", .{").?)), chosen.offset);
    // Only the target's own search: `seedFor` requests Query, Instances and allInstances in turn
    try testing.expectEqual(@as(u64, 1), w.db.executions(seed.Query));
    try testing.expectEqual(@as(u64, 1), w.db.executions(seed.Instances));
    try testing.expectEqual(@as(u64, 1), w.db.executions(seed.AllInstances));
    // Once it calls the target it is no longer skipped: its call to the target is found through the
    // call-site instance of `format`
    const calling = try std.mem.replaceOwned(u8, w.arena.allocator(), text, "w.print(\"{}\");", "print(\"{}\", .{T});");
    _ = try w.add("/p/main.zig", calling);
    const moved = (try seedFor(&w, file, "print")).?;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, calling, "print(\"{}\", .{T})").?)), moved.offset);
}

test "callers whose mentions resolve to other functions without inference are skipped" {
    // Members that can be shown to call another print from a namespace, the type of a global
    // declaration or the type of a parameter are not inferred; local values cannot be resolved that
    // way, so members using them are inferred as usual, as are aliases and members that call the
    // target, and the call site is chosen in the original order
    const text =
        \\pub fn print(comptime fmt: []const u8, args: anytype) void {
        \\    _ = fmt;
        \\    _ = args;
        \\}
        \\const Writer = struct {
        \\    pub fn print(w: Writer, comptime fmt: []const u8) void {
        \\        _ = w;
        \\        _ = fmt;
        \\    }
        \\};
        \\const ns = struct {
        \\    pub fn print(comptime fmt: []const u8) void {
        \\        _ = fmt;
        \\    }
        \\};
        \\var global: Writer = .{};
        \\fn useNamespace() void {
        \\    ns.print("{}");
        \\}
        \\fn useGlobal() void {
        \\    global.print("{}");
        \\}
        \\fn useParam(p: *const Writer) void {
        \\    p.print("{}");
        \\}
        \\fn useLocal() void {
        \\    const l: Writer = .{};
        \\    l.print("{}");
        \\}
        \\const alias = print;
        \\fn useAlias() void {
        \\    alias("{}", .{@as(u16, 1)});
        \\}
        \\fn main() void {
        \\    print("{}", .{@as(u8, 1)});
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const chosen = (try seedFor(&w, file, "print")).?;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "alias(\"{}\"").?)), chosen.offset);
    try expectCallers(&w, file, "print", &.{ "useLocal", "alias", "useAlias", "main" });
    // `seedFor` requests Query and Instances of each level in turn: the caller list is computed
    // only once
    try testing.expectEqual(@as(u64, 1), w.db.executions(seed.Callers));

    // Once it calls the target it is no longer skipped, and the earlier call site is chosen
    const calling = try std.mem.replaceOwned(u8, w.arena.allocator(), text, "ns.print(\"{}\");", "print(\"{}\", .{@as(u32, 1)});");
    _ = try w.add("/p/main.zig", calling);
    const moved = (try seedFor(&w, file, "print")).?;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, calling, "print(\"{}\", .{@as(u32").?)), moved.offset);
    try expectCallers(&w, file, "print", &.{ "useNamespace", "useLocal", "alias", "useAlias", "main" });
}

/// The callers (`seed.Callers`) in `file` of the generic function named `name` in `file` are
/// `expected`, in order
fn expectCallers(w: *World, file: FileId, name: []const u8, expected: []const []const u8) !void {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    const tree = try r.itemTree(file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.name) |n| if (std.mem.eql(u8, n, name)) break @intCast(i);
    } else return error.NoItem;
    const callers = try ctx.get(seed.Callers, .{ .root = try r.ownerKey(file, item), .in = file });
    try testing.expectEqual(expected.len, callers.len);
    for (callers, expected) |i, n| try testing.expectEqualStrings(n, tree.items[i].name.?);
}

/// Instances of the generic function `name` in `file`
fn instanceCount(w: *World, file: FileId, name: []const u8) !usize {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    const tree = try r.itemTree(file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.name) |n| if (std.mem.eql(u8, n, name)) break @intCast(i);
    } else return error.NoItem;
    return (try seed.allInstances(&r, file, item)).insts.len;
}

test "call sites are found through the names files gain and lose, without recomputing for other names" {
    const lib = "pub fn leaf(x: anytype) void { _ = x; }\nfn run() void { leaf(@as(u8, 1)); }\n";
    const header = "const lib = @import(\"lib.zig\");\n";
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/lib.zig", lib)).file;
    const other = (try w.add("/p/other.zig", header ++ "const a = 1;\n")).file;
    try w.setWorkspaceFiles(&.{ file, other });
    try testing.expectEqual(1, try instanceCount(&w, file, "leaf"));

    // A name no lookup asks for: the call sites of `leaf` are not looked for again
    const before = w.db.executions(seed.RootCallers);
    _ = try w.add("/p/other.zig", header ++ "const a = 1;\nconst unrelated = 2;\n");
    try testing.expectEqual(1, try instanceCount(&w, file, "leaf"));
    try testing.expectEqual(before, w.db.executions(seed.RootCallers));

    // The file gains the name, with a new instance; then loses it
    _ = try w.add("/p/other.zig", header ++ "fn call() void { lib.leaf(@as(u16, 1)); }\n");
    try testing.expectEqual(2, try instanceCount(&w, file, "leaf"));
    _ = try w.add("/p/other.zig", header ++ "const a = 1;\n");
    try testing.expectEqual(1, try instanceCount(&w, file, "leaf"));
}

test "call sites in the file of a generic function outside the searched files are found" {
    // The file of the function is a candidate without being a searched file
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/alone.zig", "fn leaf(x: anytype) void { _ = x; }\nconst alias = leaf;\nfn run() void { alias(@as(u8, 1)); }\n")).file;
    const other = (try w.add("/p/other.zig", "const a = 1;\n")).file;
    try w.setWorkspaceFiles(&.{other});
    try testing.expectEqual(1, try instanceCount(&w, file, "leaf"));
}

test "seed selection invalidates for arguments caller bodies signatures aliases and new candidates" {
    const decls =
        \\fn leaf(x: anytype) @TypeOf(x) { return x; }
        \\fn absent(x: anytype) void { _ = x; }
        \\fn mid(x: anytype) @TypeOf(x) { return leaf(x); }
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", decls ++ "fn run() void { _ = mid(@as(u16, 1)); }\n")).file;
    const initial = (try seedFor(&w, file, "leaf")).?.inst;
    try testing.expectEqual(null, try seedFor(&w, file, "absent"));
    const before = w.db.executions(seed.Query);
    _ = try w.add("/p/main.zig", decls ++ "fn run() void { _ = mid(@as(u32, 1)); }\n");
    try testing.expect(initial != (try seedFor(&w, file, "leaf")).?.inst);
    try testing.expect(w.db.executions(seed.Query) > before);
    _ = try w.add("/p/main.zig", decls ++
        "const alias = absent;\nfn run() void { _ = mid(@as(u32, 1)); alias(@as(u8, 0)); }\n");
    try testing.expect((try seedFor(&w, file, "absent")) != null);
    _ = try w.add("/p/main.zig", decls ++
        "const alias = leaf;\nfn run() void { _ = alias(@as(u64, 1)); }\n");
    try testing.expectEqual(null, try seedFor(&w, file, "absent"));
    const redirected = (try seedFor(&w, file, "leaf")).?.inst;
    try testing.expect(redirected != initial);
    _ = try w.add("/p/main.zig", decls);
    try testing.expectEqual(null, try seedFor(&w, file, "leaf"));
    const changed_body = try std.mem.replaceOwned(u8, w.arena.allocator(), decls, "return leaf(x);", "return leaf(@as(u64, 0));");
    _ = try w.add("/p/main.zig", try std.mem.concat(w.arena.allocator(), u8, &.{ changed_body, "fn run() void { _ = mid(@as(u8, 1)); }\n" }));
    try testing.expectEqual(redirected, (try seedFor(&w, file, "leaf")).?.inst);
    _ = try w.add("/p/main.zig", "fn leaf(x: u8) u8 { return x; }\nfn run() void { _ = leaf(1); }\n");
    try testing.expectEqual(null, try seedFor(&w, file, "leaf"));
}

test "seed importer candidates invalidate for import and project module edits" {
    const lib_text = "pub fn leaf(x: anytype) @TypeOf(x) { return x; }\n";
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const lib = (try w.add("/p/lib.zig", lib_text)).file;
    const other = (try w.add("/p/other.zig", lib_text)).file;
    const main = (try w.add("/p/main.zig", "const dep = @import(\"dep\");\nfn run() void { _ = dep.leaf(@as(u8, 1)); }\n")).file;
    const files = [_]database.ModuleGraph.FileEntry{
        .{ .file = main, .module = 0, .compile = 0 },
        .{ .file = lib, .module = 1, .compile = 0 },
        .{ .file = other, .module = 2, .compile = 0 },
    };
    try w.setGraph(null, &.{
        .{ .root = main, .imports = &.{.{ .name = "dep", .module = 1 }} },
        .{ .root = lib, .imports = &.{} },
        .{ .root = other, .imports = &.{} },
    }, &files);
    try testing.expect((try seedFor(&w, lib, "leaf")) != null);
    try testing.expectEqual(null, try seedFor(&w, other, "leaf"));
    try w.setGraph(null, &.{
        .{ .root = main, .imports = &.{.{ .name = "dep", .module = 2 }} },
        .{ .root = lib, .imports = &.{} },
        .{ .root = other, .imports = &.{} },
    }, &files);
    try testing.expectEqual(null, try seedFor(&w, lib, "leaf"));
    try testing.expect((try seedFor(&w, other, "leaf")) != null);
    _ = try w.add("/p/main.zig", "const dep = @import(\"lib.zig\");\nfn run() void { _ = dep.leaf(@as(u16, 1)); }\n");
    try testing.expect((try seedFor(&w, lib, "leaf")) != null);
    try testing.expectEqual(null, try seedFor(&w, other, "leaf"));
}

test "hover and definition combine alternate callsites with reflected loop iterations" {
    const declarations =
        \\const List = struct { pub fn deinit(_: *@This()) void {} };
        \\const Args = struct { count: usize = 0, items: List = .{} };
        \\const Empty = struct { count: usize = 0, opt: ?u8 = null };
        \\
    ;
    const body =
        \\    const info = @typeInfo(@TypeOf(arguments.*)).@"struct";
        \\    inline for (info.field_names, info.field_types) |field_name, field_type| {
        \\        switch (@typeInfo(field_type)) {
        \\            .@"struct" => @field(arguments, field_name).deinit(),
        \\            else => {},
        \\        }
        \\    }
        \\}
        \\
    ;
    const empty_call = "    var empty: Empty = .{}; cleanup(&empty);\n";
    const args_call = "    var args: Args = .{}; cleanup(&args);\n";
    const cases = [_][]const u8{
        declarations ++ "fn cleanup(arguments: anytype) void {\n" ++ body ++ "pub fn main() void {\n" ++ empty_call ++ args_call ++ "}\n",
        declarations ++ "fn cleanup(arguments: anytype) void {\n" ++ body ++ "pub fn main() void {\n" ++ args_call ++ empty_call ++ "}\n",
        declarations ++ "fn cleanup(arguments: anytype) void {\n" ++ body ++ "pub fn main() void {\n" ++ args_call ++ "}\n",
        declarations ++ "fn cleanup(arguments: *Args) void {\n" ++ body ++ "pub fn main() void {\n" ++ args_call ++ "}\n",
    };
    for (cases) |text| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const file = (try w.add("/p/main.zig", text)).file;
        try useRealStd(&w);
        for ([_][]const u8{ text, try std.mem.concat(w.arena.allocator(), u8, &.{ "// shifted\n", text }), text }) |updated| {
            _ = try w.add("/p/main.zig", updated);
            var ctx = w.db.beginRead(w.arena.allocator());
            defer ctx.end();
            var r = resolver(&w, &ctx);
            const at: u32 = @intCast(std.mem.indexOf(u8, updated, ".deinit()").? + 1);
            const info = try hover.hover(&r, file, at, &.{}, .list) orelse return error.NoHover;
            try testing.expect(std.mem.indexOf(u8, info.text, "pub fn deinit(_: *@This()) void") != null);
            const loop_at = std.mem.indexOf(u8, updated, "inline for").?;
            const loop_line = std.mem.count(u8, updated[0..loop_at], "\n") + 1;
            const origin = try std.fmt.allocPrint(w.arena.allocator(), "inferred from iteration 2 of the loop at main.zig:{d}", .{loop_line});
            try testing.expect(std.mem.indexOf(u8, info.text, origin) != null);
            const target = try definition.definition(&r, file, at) orelse return error.NoDefinition;
            try testing.expectEqual(file, target.file);
            try testing.expectEqualStrings("deinit", updated[target.start..target.end]);
            try testing.expectEqual(std.mem.indexOf(u8, updated, "deinit(_:").?, target.start);
        }
    }
}

test "builtin hover combines official documentation and inferred values" {
    const cases = [_]struct { text: []const u8, signature: []const u8, value: ?[]const u8 }{
        .{ .text = "const n = @si<|>zeOf(u32);", .signature = "@sizeOf(comptime T: type) comptime_int", .value = "comptime_int = 4" },
        .{ .text = "const n = @a<|>s(u32, 1);", .signature = "@as(comptime T: type, expression) T", .value = "u32 = 1" },
        // A rounding builtin has its result type; the call itself is the payload of the optionals,
        // however deeply they are nested
        .{ .text = "fn f(x: f32) u32 { return @ro<|>und(x); }", .signature = "@round(value: anytype) @TypeOf(value)", .value = "Inferred result:\n\n```zig\nu32\n```" },
        .{ .text = "fn f() void { const o: ?u8 = @ce<|>il(@as(f64, 2.25)); _ = o; }", .signature = "@ceil(value: anytype) @TypeOf(value)", .value = "Inferred result:\n\n```zig\nu8 = 3\n```" },
        .{ .text = "fn f() void { const o: ??u8 = @ce<|>il(@as(f32, 1.5)); _ = o; }", .signature = "@ceil(value: anytype) @TypeOf(value)", .value = "Inferred result:\n\n```zig\nu8 = 2\n```" },
        .{ .text = "@si<|>zeOf", .signature = "@sizeOf(comptime T: type) comptime_int", .value = null },
        .{ .text = "const n = @si<|>zeOf(", .signature = "@sizeOf(comptime T: type) comptime_int", .value = null },
    };
    for (cases) |case| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", case.text);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const info = try hover.hover(&r, added.file, added.cursor, &.{}, .list) orelse return error.NoHover;
        try testing.expect(std.mem.indexOf(u8, info.text, case.signature) != null);
        try testing.expect(std.mem.indexOf(u8, info.text, "https://ziglang.org/documentation/0.17.1/") != null);
        if (case.value) |value| try testing.expect(std.mem.indexOf(u8, info.text, value) != null);
        if (std.mem.indexOf(u8, case.signature, "@sizeOf") != null)
            try testing.expect(std.mem.indexOf(u8, info.text, "number of bytes") != null);
    }
}

test "builtin documentation names the version of the user's zig" {
    const signature = @import("signature_help.zig");
    for ([_]struct { database.syntax.SyntaxDialect.Value, []const u8, []const u8 }{
        .{ .zig_0_17_0, "documentation/0.17.0/#sizeOf", "0.17.1" },
        .{ .zig_0_17_1, "documentation/0.17.1/#sizeOf", "0.17.0" },
    }) |case| {
        const dialect, const link, const other = case;
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        {
            w.db.beginWrite();
            defer w.db.endWrite();
            try w.db.set(database.syntax.SyntaxDialect, {}, dialect, .high);
        }
        const hovered = try w.add("/p/hover.zig", "const n = @si<|>zeOf(u8);");
        const called = try w.add("/p/call.zig", "const n = @sizeOf(<|>u8);");
        const completed = try w.add("/p/complete.zig", "const n = @si<|>zeOf;");
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        var docs: std.ArrayList([]const u8) = .empty;
        const a = w.arena.allocator();
        try docs.append(a, (try hover.hover(&r, hovered.file, hovered.cursor, &.{}, .list) orelse return error.NoHover).text);
        try docs.append(a, (try signature.signatureHelp(&r, called.file, called.cursor) orelse return error.NoSignature).doc.?);
        for ((try completion.complete(&r, completed.file, completed.cursor, .{ .auto_import = false })).items) |item| {
            if (std.mem.eql(u8, item.label, "@sizeOf")) try docs.append(a, item.doc.?);
        }
        try testing.expectEqual(3, docs.items.len);
        for (docs.items) |doc| {
            try testing.expect(std.mem.indexOf(u8, doc, link) != null);
            try testing.expect(std.mem.indexOf(u8, doc, other) == null);
        }
    }
}

test "builtin completion exposes official details and undocumented source notes" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", "const n = @si<|>zeOf;");
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
    var size_found = false;
    var gap_found = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "@sizeOf")) {
            size_found = true;
            try testing.expectEqualStrings("@sizeOf(comptime T: type) comptime_int", item.detail.?);
            try testing.expect(std.mem.indexOf(u8, item.doc.?, "number of bytes") != null);
            try testing.expectEqual(added.cursor - 3, item.replace.?.start);
            try testing.expectEqual(added.cursor + 4, item.replace.?.end);
        }
        if (std.mem.eql(u8, item.label, "@Frame")) {
            gap_found = true;
            try testing.expect(item.detail == null);
            try testing.expect(std.mem.indexOf(u8, item.doc.?, "0.17.1") != null);
        }
    }
    try testing.expect(size_found and gap_found);
}

test "builtin signature help selects syntax nesting and argument boundaries" {
    const decls =
        \\fn ordinary(a: u32, b: u32) u32 { return a + b; }
        \\const S = struct { fn method(self: S, x: u32) u32 { _ = self; return x; } };
        \\
    ;
    const cases = [_]struct { text: []const u8, label: []const u8, active: u32, count: usize }{
        .{ .text = "const n = @as(<|>", .label = "@as(comptime T: type, expression) T", .active = 0, .count = 2 },
        .{ .text = "const n = @as(u32, <|>", .label = "@as(comptime T: type, expression) T", .active = 1, .count = 2 },
        .{ .text = "const n = @as(u32, // trailing, comment\n <|>", .label = "@as(comptime T: type, expression) T", .active = 1, .count = 2 },
        .{ .text = "const n = @as(u32, 1, <|>);", .label = "@as(comptime T: type, expression) T", .active = 1, .count = 2 },
        .{ .text = "const n = ordinary(@as(u32, <|>1), 2);", .label = "@as(comptime T: type, expression) T", .active = 1, .count = 2 },
        .{ .text = "const n = ordinary(@as(u32, 1), <|>2);", .label = "fn ordinary(a: u32, b: u32) u32", .active = 1, .count = 2 },
        .{ .text = "const n = @as(u32, ordinary(1, <|>2));", .label = "fn ordinary(a: u32, b: u32) u32", .active = 1, .count = 2 },
        .{ .text = "const n = @as(u32, ordinary(1, 2)<|>);", .label = "@as(comptime T: type, expression) T", .active = 1, .count = 2 },
        .{ .text = "const n = @TypeOf(.{ 1, 2 }, \"a,b\", <|>3);", .label = "@TypeOf(...) type", .active = 0, .count = 1 },
        .{ .text = "const n = @as(u32, // a,b\n <|>1);", .label = "@as(comptime T: type, expression) T", .active = 1, .count = 2 },
        .{ .text = "const n = @This(<|>);", .label = "@This() type", .active = 0, .count = 0 },
        .{ .text = "fn run(s: S) void { _ = s.method(<|>1); }", .label = "fn method(self: S, x: u32) u32", .active = 1, .count = 2 },
        .{ .text = "fn @\"@as\"(x: u32) u32 { return x; }\nconst n = @\"@as\"(<|>1);", .label = "fn @\"@as\"(x: u32) u32", .active = 0, .count = 1 },
    };
    for (cases) |case| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", try std.mem.concat(w.arena.allocator(), u8, &.{ decls, case.text }));
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const sig = try signature_help.signatureHelp(&r, added.file, added.cursor) orelse return error.NoSignature;
        try testing.expectEqualStrings(case.label, sig.label);
        try testing.expectEqual(case.active, sig.active);
        try testing.expectEqual(case.count, sig.params.len);
        for (sig.params) |param| try testing.expect(std.mem.indexOf(u8, sig.label, param) != null);
    }
}

test "builtin metadata excludes strings comments unknown names and escaped identifiers" {
    const cases = [_][]const u8{
        "const n = @mad<|>eup(1);",
        "const n = \"@si<|>zeOf(u32)\";",
        "// @si<|>zeOf(u32)\nconst n = 1;",
        "const @\"@si<|>zeOf\" = 1;",
        "const @\"@si<|>zeOf = 1;",
    };
    for (cases, 0..) |text, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", text);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        if (try hover.hover(&r, added.file, added.cursor, &.{}, .list)) |info|
            try testing.expect(std.mem.indexOf(u8, info.text, "https://ziglang.org/documentation/") == null);
        try testing.expect((try signature_help.signatureHelp(&r, added.file, added.cursor)) == null);
        if (i != 0) for ((try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items) |item|
            try testing.expect(item.kind != .builtin);
    }
    for ([_][]const u8{ "const n = @Frame(<|>);", "const n = @madeup(<|>);" }) |text| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", text);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        try testing.expect((try signature_help.signatureHelp(&r, added.file, added.cursor)) == null);
    }
}

test "builtin hover source gaps and argument names remain distinct" {
    const cases = [_]struct { text: []const u8, gap: bool }{
        .{ .text = "const n = @Fra<|>me();", .gap = true },
        .{ .text = "const T = u32;\nconst n = @sizeOf(T<|>);", .gap = false },
        .{ .text = "fn @\"@as\"(x: u32) u32 { return x; }\nconst n = @\"@a<|>s\"(1);", .gap = false },
    };
    for (cases) |case| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", case.text);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const info = try hover.hover(&r, added.file, added.cursor, &.{}, .list) orelse return error.NoHover;
        if (case.gap) {
            try testing.expect(std.mem.indexOf(u8, info.text, "0.17.1") != null);
            try testing.expect(std.mem.indexOf(u8, info.text, "@Frame(") == null);
        } else {
            try testing.expect(std.mem.indexOf(u8, info.text, "https://ziglang.org/documentation/") == null);
            try testing.expect(std.mem.indexOf(u8, info.text, "Inferred result:") == null);
        }
    }
}

test "auto import ordinary contexts and full token replacement" {
    const cases = [_][]const u8{
        "const value = st<|>andard;",
        "const value: st<|>andard = undefined;",
        "fn run() void { _ = st<|>andard; }",
        "const value = st<|>andard",
        "const value = @\"st<|>andard\";",
    };
    for (cases) |source| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", source);
        const std_file = (try w.add("/lib/std/std.zig", "")).file;
        try w.setGraph(std_file, &.{}, &.{});
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const result = try completion.complete(&r, added.file, added.cursor, .{});
        const candidate = for (result.items) |item| {
            if (std.mem.eql(u8, item.label, "std") and item.import_edit != null) break item;
        } else return error.MissingAutoImport;
        try testing.expect(candidate.qualifier != null);
        try testing.expect(candidate.sort != null);
        try testing.expectEqualStrings("const std = @import(\"std\");\n", candidate.import_edit.?.text);
        const text = (try r.ctx.get(database.syntax.SourceText, added.file)).text;
        try testing.expect(std.mem.startsWith(u8, candidate.filter.?, text[candidate.replace.?.start..added.cursor]));
        const replaced = text[candidate.replace.?.start..candidate.replace.?.end];
        try testing.expectEqualStrings(if (std.mem.indexOf(u8, source, "@\"") != null) "@\"standard\"" else "standard", replaced);
        try testing.expect(candidate.import_edit.?.end <= candidate.replace.?.start);
        const disabled = try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false });
        try testing.expect(!disabled.is_incomplete);
        for (disabled.items) |item| try testing.expect(item.import_edit == null);
    }
}

test "auto import does not leak into non-name contexts" {
    const cases = [_]struct { []const u8, bool }{
        .{ "const st<|>d = 1;", false },
        .{ "fn st<|>d() void {}", false },
        .{ "fn run(st<|>d: u32) void {}", false },
        .{ "const S = struct { st<|>d: u32 };", false },
        .{ "const value = \"st<|>d\";", false },
        .{ "// st<|>d\nconst value = 1;", false },
        .{ "const value = @import(\"st<|>d\");", false },
        .{ "const value = object.st<|>d;", false },
        .{ "const value = .st<|>d;", false },
        .{ "const value = error.st<|>d;", false },
        .{ "fn run() void { break :st<|>d; }", false },
        // Primitive names, `_` and an empty name: typing more makes a name that takes auto-import
        // candidates, so the list is incomplete
        .{ "const value: u3<|>2 = undefined;", true },
        .{ "fn run() void { _<|> = 1; }", true },
        .{ "fn run() void { <|> }", true },
    };
    for (cases) |case| {
        const source, const incomplete = case;
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", source);
        const std_file = (try w.add("/lib/std/std.zig", "")).file;
        try w.setGraph(std_file, &.{}, &.{});
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const baseline = try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false });
        const result = try completion.complete(&r, added.file, added.cursor, .{});
        try testing.expectEqual(incomplete, result.is_incomplete);
        // These contexts offer no auto-imports, and the results of plain completion are not lost or
        // rewritten because of it
        try testing.expectEqual(baseline.items.len, result.items.len);
        for (result.items) |item| {
            try testing.expect(item.import_edit == null);
            try testing.expect(item.filter == null);
        }
    }
}

test "auto import does not rewrite bare enum or union member declarations" {
    const members = [_][]const u8{
        "const E = enum { standard<|> };",
        "const E = enum { standard<|> = 1 };",
        "const E = enum(u8) { standard<|> };",
        "const E = union(enum) { standard<|> };",
    };
    for (members) |source| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.fmt.allocPrint(w.arena.allocator(), "//- /p/main.zig module:root\n{s}\n" ++
            "//- /p/types.zig in:root\npub const standard = u32;\n", .{source});
        const fixture = try w.fixture(text);
        const cursor = fixture.cursor.?;
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
        for (result.items) |item| {
            try testing.expect(item.import_edit == null);
            try testing.expect(item.filter == null);
        }
    }
    // Tuple fields of a struct have no colon, but the type expression is a real name reference and
    // should still be auto-imported
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const fixture = try w.fixture(
        \\//- /p/main.zig module:root
        \\const S = struct { standard<|> };
        \\//- /p/types.zig in:root
        \\pub const standard = u32;
    );
    const cursor = fixture.cursor.?;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
    const candidate = for (result.items) |item| {
        if (item.filter) |filter| if (std.mem.eql(u8, filter, "standard")) break item;
    } else return error.MissingTupleFieldAutoImport;
    try testing.expect(candidate.import_edit != null);
}

test "auto import is not offered outside zig source files" {
    // Inserting an import declaration into a `.zon` file would break it; no auto-import indexing is
    // started for it either
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/build.zig.zon", ".{ .value = st<|>d }");
    const std_file = (try w.add("/lib/std/std.zig", "")).file;
    try w.setGraph(std_file, &.{}, &.{});
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const result = try completion.complete(&r, added.file, added.cursor, .{});
    try testing.expect(!result.import_position);
    for (result.items) |item| try testing.expect(item.import_edit == null);
    const detected = try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false, .detect_import_position = true });
    try testing.expect(!detected.import_position);
}

/// The snippet inserted by the item named `label` at the cursor: `-` when it has no snippet,
/// `missing` when there is no such item
fn snippetOf(w: *World, file: FileId, offset: u32, label: []const u8, options: completion.Options) ![]const u8 {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    for ((try completion.complete(&r, file, offset, options)).items) |it| {
        if (std.mem.eql(u8, it.label, label)) return w.arena.allocator().dupe(u8, it.snippet orelse "-");
    }
    return "missing";
}

const call_snippet_decls =
    \\const S = struct {
    \\    v: u8,
    \\    pub fn init(a: u8) S {
    \\        return .{ .v = a };
    \\    }
    \\    pub fn get(self: S, index: usize, comptime T: type, value: anytype) T {
    \\        _ = .{ self, index, value };
    \\        return undefined;
    \\    }
    \\    pub fn reset(self: *S) void {
    \\        self.v = 0;
    \\    }
    \\};
    \\fn add(a: u32, b: u32) u32 {
    \\    return a + b;
    \\}
    \\fn noArgs() void {}
    \\fn discard(_: u8, label: []const u8) void {
    \\    _ = label;
    \\}
    \\extern fn printf(format: [*:0]const u8, ...) c_int;
    \\const alias = add;
    \\fn apply(f: *const fn (u32, u32) u32, x: u32) u32 {
    \\    return f(x, x);
    \\}
    \\const Handler = struct { cb: *const fn () void, n: u32 };
    \\const HandlerFn = *const fn () void;
    \\
;

test "completion: function and builtin calls insert argument placeholders with snippets" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "fn t() void {\n    ad<|>\n}", "add", "add(${1:a}, ${2:b})" },
        .{ "fn t() void {\n    const x = <|>\n}", "add", "add(${1:a}, ${2:b})" },
        .{ "fn t() void {\n    noA<|>\n}", "noArgs", "noArgs()" },
        // A parameter named `_` uses its type as the placeholder; a varargs function ends with a
        // stop before the `)`
        .{ "fn t() void {\n    dis<|>\n}", "discard", "discard(${1:u8}, ${2:label})" },
        .{ "fn t() void {\n    pri<|>\n}", "printf", "printf(${1:format}$2)" },
        // Methods of a value skip the receiver, and comptime and anytype parameters still get
        // placeholders; calls through the type do not skip the receiver
        .{ "fn t(s: S) void {\n    s.ge<|>\n}", "get", "get(${1:index}, ${2:T}, ${3:value})" },
        .{ "fn t(s: *S) void {\n    s.<|>\n}", "reset", "reset()" },
        .{ "fn t() void {\n    S.ge<|>\n}", "get", "get(${1:self}, ${2:index}, ${3:T}, ${4:value})" },
        // Member paths of local values are called through a value and skip the receiver too
        .{ "fn t(s: S) void {\n    _ = s;\n    ge<|>\n}", "s.get", "s.get(${1:index}, ${2:T}, ${3:value})" },
        .{ "fn t(s: *S) void {\n    _ = s;\n    rese<|>\n}", "s.reset", "s.reset()" },
        // decl literal
        .{ "fn t() void {\n    const s: S = .in<|>\n}", "init", "init(${1:a})" },
        // Function aliases
        .{ "fn t() void {\n    ali<|>\n}", "alias", "alias(${1:a}, ${2:b})" },
        .{ "fn t() void {\n    const f = add;\n    f<|>\n}", "f", "f(${1:a}, ${2:b})" },
        // Parentheses already follow the cursor
        .{ "fn t() void {\n    ad<|>(1, 2);\n}", "add", "-" },
        .{ "fn t() void {\n    a<|>dd(1, 2);\n}", "add", "-" },
        .{ "fn t(s: S) void {\n    s.g<|>et(1, u8, 2);\n}", "get", "-" },
        // Positions that expect a function value insert only the name
        .{ "fn t() void {\n    _ = apply(ad<|>, 1);\n}", "add", "-" },
        .{ "fn t() void {\n    _ = apply(<|>);\n}", "add", "-" },
        .{ "fn t() void {\n    _ = apply(add, ad<|>);\n}", "add", "add(${1:a}, ${2:b})" },
        .{ "fn t() void {\n    _ = &ad<|>;\n}", "add", "-" },
        .{ "fn t() void {\n    @call(.auto, ad<|>, .{ 1, 2 });\n}", "add", "-" },
        .{ "fn t() void {\n    const f: *const fn (u32, u32) u32 = ad<|>;\n}", "add", "-" },
        .{ "fn t() void {\n    const f: *const fn (u32, u32) u32 = <|>\n}", "add", "-" },
        .{ "fn t() void {\n    const h: Handler = .{ .cb = noA<|>, .n = 1 };\n}", "noArgs", "-" },
        .{ "fn t() void {\n    const h: Handler = .{ .cb = <|> };\n}", "noArgs", "-" },
        .{ "fn t() void {\n    const h: Handler = .{ .cb = noArgs, .n = ad<|> };\n}", "add", "add(${1:a}, ${2:b})" },
        .{ "fn t() void {\n    var g: ?*const fn () void = null;\n    g = noA<|>;\n}", "noArgs", "-" },
        .{ "fn t() *const fn () void {\n    return noA<|>;\n}", "noArgs", "-" },
        .{ "const cb: *const fn () void = noA<|>;", "noArgs", "-" },
        // Elements of arrays and tuples of functions, by syntax or by the computed type
        .{ "fn t() void {\n    const fs = [_]*const fn () void{ noA<|> };\n    _ = fs;\n}", "noArgs", "-" },
        .{ "fn t() void {\n    const fs = [_]HandlerFn{ noArgs, noA<|> };\n    _ = fs;\n}", "noArgs", "-" },
        .{ "fn t() void {\n    const fs = [_]HandlerFn{ noArgs, <|> };\n    _ = fs;\n}", "noArgs", "-" },
        .{ "fn t() void {\n    const fs: [2]HandlerFn = .{ noArgs, noA<|> };\n    _ = fs;\n}", "noArgs", "-" },
        .{ "fn t() void {\n    const fs: struct { HandlerFn, u32 } = .{ noA<|>, 1 };\n    _ = fs;\n}", "noArgs", "-" },
        .{ "fn t() void {\n    const xs = [_]u32{ ad<|> };\n    _ = xs;\n}", "add", "add(${1:a}, ${2:b})" },
        .{ "fn t() void {\n    const xs: struct { HandlerFn, u32 } = .{ noArgs, ad<|> };\n    _ = xs;\n}", "add", "add(${1:a}, ${2:b})" },
        // Branches take the position of the expression they produce
        .{ "fn t(c: bool) void {\n    const h: HandlerFn = if (c) noArgs else noA<|>;\n    _ = h;\n}", "noArgs", "-" },
        .{ "fn t(o: ?HandlerFn) void {\n    const h: HandlerFn = o orelse noA<|>;\n    _ = h;\n}", "noArgs", "-" },
        .{ "fn t(e: anyerror!HandlerFn) void {\n    const h: HandlerFn = e catch noA<|>;\n    _ = h;\n}", "noArgs", "-" },
        .{ "fn t(x: u8) void {\n    const h: HandlerFn = switch (x) {\n        0 => noArgs,\n        else => noA<|>,\n    };\n    _ = h;\n}", "noArgs", "-" },
        .{ "fn t() void {\n    const h: HandlerFn = blk: {\n        break :blk noA<|>;\n    };\n    _ = h;\n}", "noArgs", "-" },
        .{ "fn t(c: bool) void {\n    const x: u32 = if (c) 1 else ad<|>;\n    _ = x;\n}", "add", "add(${1:a}, ${2:b})" },
        // Builtins
        .{ "fn t() void {\n    _ = @Thi<|>;\n}", "@This", "@This()" },
        .{ "fn t() void {\n    _ = @a<|>s;\n}", "@as", "@as(${1:T}, ${2:expression})" },
        .{ "fn t() void {\n    _ = @TypeO<|>;\n}", "@TypeOf", "@TypeOf($1)" },
        .{ "fn t() void {\n    _ = @a<|>s(u8, 1);\n}", "@as", "-" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.mem.concat(w.arena.allocator(), u8, &.{ call_snippet_decls, c[0], "\n" });
        const added = try w.add("/p/main.zig", text);
        const got = try snippetOf(&w, added.file, added.cursor, c[1], .{ .auto_import = false, .snippets = true });
        testing.expectEqualStrings(c[2], got) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }
}

test "completion: anytype parameters take a function name when another parameter is its ArgsTuple" {
    // `std.meta.ArgsTuple` accepts only function types
    const std_root =
        \\pub const meta = struct {
        \\    pub fn ArgsTuple(comptime Function: type) type {
        \\        _ = Function;
        \\        return struct {};
        \\    }
        \\};
        \\
    ;
    const decls =
        \\const std = @import("std");
        \\const Io = struct {
        \\    pub fn async(io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
        \\        _ = .{ io, args };
        \\    }
        \\};
        \\const ArgsTuple = std.meta.ArgsTuple;
        \\fn run(function: anytype, args: ArgsTuple(@TypeOf(function))) void {
        \\    _ = args;
        \\}
        \\fn same(value: anytype, other: @TypeOf(value)) void {
        \\    _ = other;
        \\}
        \\fn work(n: u32) void {
        \\    _ = n;
        \\}
        \\
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "fn t(io: Io) void {\n    io.async(wor<|>, .{1});\n}", "-" },
        .{ "fn t(io: Io) void {\n    io.async(<|>, .{1});\n}", "-" },
        .{ "fn t() void {\n    run(wor<|>, .{1});\n}", "-" },
        // Other `anytype` parameters may receive any value
        .{ "fn t() void {\n    same(wor<|>, 1);\n}", "work(${1:n})" },
        .{ "fn t(io: Io) void {\n    io.async(work, .{wor<|>});\n}", "work(${1:n})" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const fixture = try snippetFixture(&w, try std.mem.concat(w.arena.allocator(), u8, &.{ decls, c[0] }), std_root);
        const cursor = fixture.cursor.?;
        testing.expectEqualStrings(c[1], try snippetOf(&w, cursor.file, cursor.offset, "work", .{ .auto_import = false, .snippets = true })) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }
}

test "completion: anytype parameters that are called as functions take a function name" {
    const decls =
        \\const Ctx = struct {
        \\    fn work(n: u32) void {
        \\        _ = n;
        \\    }
        \\};
        \\fn work(n: u32) void {
        \\    _ = n;
        \\}
        \\fn viaCall(comptime f: anytype, args: anytype) void {
        \\    @call(.auto, f, args);
        \\}
        \\fn direct(f: anytype) void {
        \\    f(1);
        \\}
        \\fn info(comptime f: anytype) usize {
        \\    return @typeInfo(@TypeOf(f)).@"fn".params.len;
        \\}
        \\fn forward(comptime function: anytype, args: anytype) void {
        \\    const Inner = struct {
        \\        fn start() void {
        \\            viaCall(function, args);
        \\        }
        \\    };
        \\    Inner.start();
        \\}
        \\const Impl = struct {
        \\    fn spawn(comptime f: anytype, args: anytype) void {
        \\        direct(f);
        \\        _ = args;
        \\    }
        \\};
        \\fn spawn(comptime function: anytype, args: anytype) void {
        \\    Impl.spawn(function, args);
        \\}
        \\fn value(v: anytype) void {
        \\    _ = v;
        \\}
        \\fn passValue(v: anytype) void {
        \\    value(v);
        \\}
        \\fn hop1(f: anytype) void {
        \\    hop2(f);
        \\}
        \\fn hop2(f: anytype) void {
        \\    hop3(f);
        \\}
        \\fn hop3(f: anytype) void {
        \\    hop4(f);
        \\}
        \\fn hop4(f: anytype) void {
        \\    hop5(f);
        \\}
        \\fn hop5(f: anytype) void {
        \\    hop6(f);
        \\}
        \\fn hop6(f: anytype) void {
        \\    direct(f);
        \\}
        \\fn even(f: anytype, n: u32) void {
        \\    if (n == 0) f(0) else odd(f, n - 1);
        \\}
        \\fn odd(f: anytype, n: u32) void {
        \\    even(f, n - 1);
        \\}
        \\fn ping(v: anytype, n: u32) void {
        \\    if (n > 0) pong(v, n - 1);
        \\}
        \\fn pong(v: anytype, n: u32) void {
        \\    ping(v, n);
        \\}
        \\fn again(v: anytype) void {
        \\    again(v);
        \\}
        \\
    ;
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "fn t() void {\n    viaCall(wor<|>, .{1});\n}", "work", "-" },
        .{ "fn t() void {\n    viaCall(<|>, .{1});\n}", "work", "-" },
        .{ "fn t() void {\n    viaCall(Ctx.wor<|>, .{1});\n}", "work", "-" },
        .{ "fn t() void {\n    direct(wor<|>);\n}", "work", "-" },
        .{ "fn t() void {\n    _ = info(wor<|>);\n}", "work", "-" },
        // Passed on to a parameter that is called, also from a function of a local struct
        .{ "fn t() void {\n    forward(wor<|>, .{1});\n}", "work", "-" },
        .{ "fn t() void {\n    spawn(wor<|>, .{1});\n}", "work", "-" },
        // Every call of a chain is followed, and functions that pass the parameter to each other
        // are looked into once
        .{ "fn t() void {\n    hop1(wor<|>);\n}", "work", "-" },
        .{ "fn t() void {\n    odd(wor<|>, 3);\n}", "work", "-" },
        // Other `anytype` parameters may receive any value
        .{ "fn t() void {\n    value(wor<|>);\n}", "work", "work(${1:n})" },
        .{ "fn t() void {\n    passValue(wor<|>);\n}", "work", "work(${1:n})" },
        .{ "fn t() void {\n    viaCall(work, .{wor<|>});\n}", "work", "work(${1:n})" },
        .{ "fn t() void {\n    ping(wor<|>, 3);\n}", "work", "work(${1:n})" },
        .{ "fn t() void {\n    again(wor<|>);\n}", "work", "work(${1:n})" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", try std.mem.concat(w.arena.allocator(), u8, &.{ decls, c[0], "\n" }));
        testing.expectEqualStrings(c[2], try snippetOf(&w, added.file, added.cursor, c[1], .{ .auto_import = false, .snippets = true })) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }
}

test "completion: the function argument of std.Thread.spawn takes a function name" {
    const decls =
        \\const std = @import("std");
        \\fn worker(id: u32) void {
        \\    _ = id;
        \\}
        \\fn testWorker(allocator: std.mem.Allocator) !void {
        \\    _ = allocator;
        \\}
        \\
    ;
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "pub fn main() !void {\n    const t = try std.Thread.spawn(.{}, work<|>, .{@as(u32, 1)});\n    t.join();\n}", "worker", "-" },
        .{ "pub fn main() !void {\n    const t = try std.Thread.spawn(.{}, <|>, .{@as(u32, 1)});\n    t.join();\n}", "worker", "-" },
        .{ "test {\n    try std.testing.checkAllAllocationFailures(std.testing.allocator, testW<|>, .{});\n}", "testWorker", "-" },
        // Other `anytype` parameters keep the call snippet
        .{ "test {\n    try std.testing.expectEqual(work<|>, 1);\n}", "worker", "worker(${1:id})" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const std_root = try w.vfs.intern(try std.fs.path.join(w.arena.allocator(), &.{ env.std_dir, "std.zig" }));
        // `std.Thread` picks its implementation by the target in builtin
        w.default_builtin = (try w.add("/b/builtin.zig",
            \\const std = @import("std");
            \\pub const single_threaded = false;
            \\pub const os: std.Target.Os = .{ .tag = .linux, .version_range = .{ .none = {} } };
            \\pub const link_libc = false;
            \\
        )).file;
        const added = try w.add("/p/main.zig", try std.mem.concat(w.arena.allocator(), u8, &.{ decls, c[0], "\n" }));
        try w.setGraph(std_root, &.{}, &.{});
        testing.expectEqualStrings(c[2], try snippetOf(&w, added.file, added.cursor, c[1], .{ .auto_import = false, .snippets = true })) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }
}

test "completion: call snippets without argument placeholders, and nothing changes without snippets" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "fn t() void {\n    ad<|>\n}", "add", "add($1)" },
        .{ "fn t() void {\n    noA<|>\n}", "noArgs", "noArgs()" },
        .{ "fn t(s: S) void {\n    s.ge<|>\n}", "get", "get($1)" },
        .{ "fn t(s: *S) void {\n    s.<|>\n}", "reset", "reset()" },
        .{ "fn t() void {\n    _ = @Thi<|>;\n}", "@This", "@This()" },
        .{ "fn t() void {\n    _ = @a<|>s;\n}", "@as", "@as($1)" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.mem.concat(w.arena.allocator(), u8, &.{ call_snippet_decls, c[0], "\n" });
        const added = try w.add("/p/main.zig", text);
        const got = try snippetOf(&w, added.file, added.cursor, c[1], .{ .auto_import = false, .snippets = true, .argument_placeholders = false });
        testing.expectEqualStrings(c[2], got) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
        // Without snippets no item has a snippet; with snippets the other items are unchanged
        // (apart from the added snippet items)
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const plain = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false })).items;
        const with = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false, .snippets = true })).items;
        var rest: std.ArrayList(completion.Item) = .empty;
        for (with) |s| if (s.kind != .snippet) try rest.append(w.arena.allocator(), s);
        try testing.expectEqual(plain.len, rest.items.len);
        for (plain, rest.items) |p, s| {
            try testing.expect(p.snippet == null and p.kind != .snippet);
            try testing.expectEqualStrings(p.label, s.label);
            if (s.snippet == null) try testing.expectEqual(p.replace, s.replace);
        }
    }
}

test "completion: auto-import candidates for functions insert a call along with the import" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const fixture = try w.fixture(
        \\//- /p/main.zig module:root
        \\fn t() void {
        \\    help<|>
        \\}
        \\//- /p/util.zig in:root
        \\pub fn helper(n: u32) void {
        \\    _ = n;
        \\}
    );
    const cursor = fixture.cursor.?;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const result = try completion.complete(&r, cursor.file, cursor.offset, .{ .snippets = true });
    const candidate = for (result.items) |item| {
        if (item.import_edit != null and std.mem.endsWith(u8, item.label, "helper")) break item;
    } else return error.MissingAutoImport;
    const expected = try std.fmt.allocPrint(w.arena.allocator(), "{s}(${{1:n}})", .{candidate.label});
    try testing.expectEqualStrings(expected, candidate.snippet.?);
    try testing.expectEqual(cursor.offset - "help".len, candidate.replace.?.start);
    try testing.expectEqual(cursor.offset, candidate.replace.?.end);
    try testing.expect(candidate.sort != null);
}

test "completion: call snippets follow edits to the called function" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const main = try w.add("/p/main.zig", "const b = @import(\"b.zig\");\nfn t() void {\n    b.<|>\n}\n");
    const steps = [_]struct { []const u8, []const u8 }{
        .{ "pub fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n", "add(${1:a}, ${2:b})" },
        // The name and position of the function stay the same; only the parameters change
        .{ "pub fn add(x: u32, y: u32, z: u32) u32 {\n    return x + y + z;\n}\n", "add(${1:x}, ${2:y}, ${3:z})" },
        .{ "pub fn add(x: u32, _: u8, ...) callconv(.c) u32 {\n    return x;\n}\n", "add(${1:x}, ${2:u8}$3)" },
        .{ "pub fn add() u32 {\n    return 0;\n}\n", "add()" },
    };
    for (steps) |step| {
        _ = try w.add("/p/b.zig", step[0]);
        try testing.expectEqualStrings(step[1], try snippetOf(&w, main.file, main.cursor, "add", .{ .auto_import = false, .snippets = true }));
    }
}

/// Labels of the snippet items (`.snippet`) at the cursor, joined with `, `
fn snippetLabels(w: *World, file: FileId, offset: u32) ![]const u8 {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    var labels: std.ArrayList([]const u8) = .empty;
    for ((try completion.complete(&r, file, offset, .{ .auto_import = false, .snippets = true })).items) |it| {
        if (it.kind == .snippet) try labels.append(w.arena.allocator(), it.label);
    }
    return std.mem.join(w.arena.allocator(), ", ", labels.items);
}

/// A standard library with only `process.Init` and `Io.Writer`
const snippet_std_root =
    \\pub const process = struct {
    \\    pub const Init = struct {};
    \\};
    \\pub const Io = struct {
    \\    pub const Writer = struct {
    \\        pub const Error = error{WriteFailed};
    \\    };
    \\};
    \\
;

/// A project with `text` as the root file of module app and `std_root` as the root file of the
/// standard library
fn snippetFixture(w: *World, text: []const u8, std_root: []const u8) !World.Fixture {
    return w.fixture(try std.mem.concat(w.arena.allocator(), u8, &.{ "//- /p/main.zig module:app\n", text, "\n//- /zig/std/std.zig std\n", std_root }));
}

test "completion: statement and declaration snippets follow the syntax position" {
    const statements = "if, if else, for, fori, while, switch";
    const logging = ", print, log err, log warn, log info, log debug";
    const declarations = "fn, pub fn, test, struct, enum, union, union tagged, error set, import";
    const cases = [_]struct { []const u8, []const u8 }{
        // Start of a statement in a block; snippets that use `std` only when `std` is the standard
        // library
        .{ "fn t() void {\n    <|>\n}", statements },
        // Snippets that match the input come first
        .{ "fn t() void {\n    wh<|>\n}", "while, if, if else, for, fori, switch" },
        .{ "const std = @import(\"std\");\nfn t() void {\n    const a = 1;\n    _ = a;\n    <|>\n}", statements ++ logging },
        .{ "const std = struct {};\nfn t() void {\n    <|>\n}", statements },
        .{ "fn t() void {\n    if (true) {}\n    <|>\n}", statements },
        .{ "fn t(x: u8) void {\n    switch (x) {\n        else => {},\n    }\n    <|>\n}", statements },
        .{ "test \"a\" {\n    <|>\n}", statements },
        // None inside expressions
        .{ "fn t() void {\n    const a = <|>\n}", "" },
        .{ "fn t() void {\n    _ = .{ 1, <|> };\n}", "" },
        .{ "fn t() void {\n    t(<|>);\n}", "" },
        .{ "fn t(x: u8) void {\n    switch (x) {\n        <|>\n    }\n}", "" },
        .{ "fn t() void {\n    defer <|>\n}", "" },
        // The word starts inside a token: after the `.` of a number, between the characters of an
        // operator (computing the position used to slice the text backwards and crash)
        .{ "fn t() void {\n    const x = 1.5<|>;\n    _ = x;\n}", "" },
        .{ "fn t() void {\n    const x = 1e-5<|>;\n    _ = x;\n}", "" },
        .{ "const x = 0x1.8p1<|>;", "" },
        .{ "fn t(x: u8) void {\n    switch (x) {\n        else =<|>> {},\n    }\n}", "" },
        .{ "fn t(a: []const u8) void {\n    _ = a +<|>+ a;\n}", "" },
        // Start of a container member
        .{ "<|>", declarations ++ ", std, builtin, main" },
        .{ "const a = 1;\nfo<|>", declarations ++ ", std, builtin, main" },
        .{ "pub <|>", "fn, struct, enum, union, union tagged, error set, import, main" },
        .{ "/// doc\n<|>", "fn, pub fn, struct, enum, union, union tagged, error set, import, std, builtin, main" },
        .{ "const std = @import(\"std\");\npub fn main() void {}\n<|>", declarations ++ ", builtin" },
        .{ "const S = struct {\n    a: u8,\n    <|>\n};", declarations ++ ", std, builtin" },
        .{ "const std = @import(\"std\");\nconst S = struct {\n    a: u8,\n    <|>\n};", declarations ++ ", builtin, format" },
        .{ "const std = @import(\"std\");\nconst S = opaque {\n    <|>\n};", declarations ++ ", builtin" },
        // A file with fields is a struct and gets `format` as well
        .{ "const std = @import(\"std\");\na: u8,\n<|>", declarations ++ ", builtin, main, format" },
        .{ "fn t() void {\n    const S = struct {\n        <|>\n    };\n    _ = S;\n}", declarations ++ ", std, builtin" },
        // No declarations between fields
        .{ "const S = struct {\n    a: u8,\n    <|>\n    b: u8,\n};", "" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const fixture = try snippetFixture(&w, c[0], snippet_std_root);
        const cursor = fixture.cursor.?;
        testing.expectEqualStrings(c[1], try snippetLabels(&w, cursor.file, cursor.offset)) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }
}

test "completion: snippets insert declarations that fit the position and the standard library" {
    const cases = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "<|>", snippet_std_root, "main", "pub fn main() !void {$0}" },
        .{ "<|>", snippet_std_root, "std", "const std = @import(\"std\");" },
        .{ "<|>", snippet_std_root, "fn", "fn ${1:name}($2) ${3:!void} {$0}" },
        .{ "<|>", snippet_std_root, "test", "test \"${1:name}\" {$0}" },
        // `main` takes `std.process.Init` when the standard library has it; `pub` is not inserted
        // again when already written
        .{ "const std = @import(\"std\");\n<|>", snippet_std_root, "main", "pub fn main(init: std.process.Init) !void {$0}" },
        .{ "const std = @import(\"std\");\n<|>", "", "main", "pub fn main() !void {$0}" },
        .{ "const std = @import(\"std\");\npub <|>", snippet_std_root, "main", "fn main(init: std.process.Init) !void {$0}" },
        .{ "pub <|>", snippet_std_root, "struct", "const ${1:Name} = struct {$0};" },
        .{ "const std = @import(\"std\");\nconst S = struct {\n    <|>\n};", snippet_std_root, "format", "pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {$0}" },
        .{ "const std = @import(\"std\");\nconst S = struct {\n    <|>\n};", "", "format", "missing" },
        .{ "const std = @import(\"std\");\nfn t() void {\n    <|>\n}", snippet_std_root, "print", "std.debug.print(\"$1\", .{$0});" },
        .{ "fn t() void {\n    <|>\n}", snippet_std_root, "for", "for ($1) |${2:value}| {$0}" },
    };
    for (cases, 0..) |c, i| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const fixture = try snippetFixture(&w, c[0], c[1]);
        const cursor = fixture.cursor.?;
        testing.expectEqualStrings(c[3], try snippetOf(&w, cursor.file, cursor.offset, c[2], .{ .auto_import = false, .snippets = true })) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }

    // The replace range is the whole word at the cursor (keywords included), and the detail shows
    // the inserted text
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", "fn t() void {\n    wh<|>ile\n}\n");
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = (try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false, .snippets = true })).items;
    const item = for (items) |it| {
        if (it.kind == .snippet and std.mem.eql(u8, it.label, "for")) break it;
    } else return error.MissingSnippet;
    try testing.expectEqual(added.cursor - 2, item.replace.?.start);
    try testing.expectEqual(added.cursor + 3, item.replace.?.end);
    try testing.expectEqualStrings("for (…) |value| {}", item.detail.?);
}

test "completion: no snippets outside zig source files" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/build.zig.zon", ".{\n    .value = <|>\n}");
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    for ((try completion.complete(&r, added.file, added.cursor, .{ .snippets = true })).items) |it| {
        try testing.expect(it.snippet == null and it.kind != .snippet);
    }
}

test "auto import preserves rendered qualified paths and metadata" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const fixture = try w.fixture(
        \\//- /p/main.zig module:root
        \\const Alias = @import("types.zig").Outer;
        \\const value = Ind<|>ex;
        \\//- /p/types.zig in:root
        \\pub const Outer = struct {
        \\    pub const Node = struct {
        \\        pub const Index = u32;
        \\    };
        \\};
    );
    const cursor = fixture.cursor.?;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
    const candidate = for (result.items) |item| {
        if (std.mem.eql(u8, item.label, "Alias.Node.Index")) break item;
    } else return error.MissingQualifiedAutoImport;
    try testing.expectEqualStrings("Index", candidate.filter.?);
    try testing.expect(candidate.import_edit == null);
    try testing.expect(candidate.qualifier != null);
    try testing.expect(candidate.sort != null);
    try testing.expectEqual(@as(u32, 5), candidate.replace.?.end - candidate.replace.?.start);
}

test "selected auto-import candidates describe the signature, docs and where the target is defined" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const fixture = try w.fixture(
        \\//- /p/src/main.zig module:app deps:wire=dep
        \\fn main() void { _ = <|>missing; }
        \\//- /p/src/util/lines.zig in:app
        \\//! Line utilities.
        \\
        \\/// Offsets of line starts.
        \\pub const LineIndex = struct {};
        \\pub fn lineOf(offset: u32) u32 { return offset; }
        \\/// Text helpers.
        \\pub const txt = @import("text.zig");
        \\//- /p/src/util/text.zig in:app
        \\//! Text utilities.
        \\pub const max = 4;
        \\//- /dep/src/root.zig module:dep
        \\pub const Header = struct {};
        \\//- /zig/std/std.zig std
        \\pub const mem = @import("mem.zig");
        \\//- /zig/std/mem.zig std
        \\pub fn eql() bool { return true; }
    );
    const cursor = fixture.cursor.?;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const imports = @import("../ide_db/imports.zig");
    const cases = [_]struct { prefix: []const u8, label: []const u8, detail: []const u8, doc: []const u8 }{
        .{ .prefix = "LineIn", .label = "LineIndex", .detail = "const LineIndex = struct", .doc = "Offsets of line starts.\n\nDefined in `util/lines.zig:4`" },
        .{ .prefix = "lineO", .label = "lineOf", .detail = "pub fn lineOf(offset: u32) u32", .doc = "Defined in `util/lines.zig:5`" },
        // A constant whose value is a file: its own doc, then the `//!` doc of that file
        .{ .prefix = "tx", .label = "txt", .detail = "const txt: type = text", .doc = "Text helpers.\n\nText utilities.\n\nDefined in `util/lines.zig:7`" },
        // The file itself: the import expression and the `//!` docs at the start of the file
        .{ .prefix = "lines", .label = "lines", .detail = "@import(\"util/lines.zig\")", .doc = "Line utilities.\n\nFile `util/lines.zig`" },
        // The standard library by its path under `std/`; other modules by the name the current file
        // imports them under
        .{ .prefix = "eq", .label = "eql", .detail = "pub fn eql() bool", .doc = "Defined in `std/mem.zig:1`" },
        .{ .prefix = "Head", .label = "Header", .detail = "const Header = struct", .doc = "Defined in `wire/root.zig:1`" },
    };
    for (cases) |case| {
        const result = try imports.complete(&r, cursor.file, cursor.offset, .unknown, case.prefix, 128, .{});
        const candidate = for (result.items) |item| {
            if (std.mem.eql(u8, item.label, case.label)) break item;
        } else return error.MissingAutoImport;
        const description = try completion.describe(&r, cursor.file, candidate.target);
        try testing.expectEqualStrings(case.detail, description.detail);
        try testing.expectEqualStrings(case.doc, description.doc);
    }
}

test "auto import escaped filters preserve the raw input prefix" {
    const sources = [_][]const u8{
        "const value = @\"Ser<|>ver name\";",
        "const value = @\"S\\x65r<|>ver name\";",
        "const value = @\"Ser\"<|>;",
    };
    for (sources) |source| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.fmt.allocPrint(w.arena.allocator(), "//- /p/main.zig module:root\nconst Alias = @import(\"types.zig\");\n{s}\n" ++
            "//- /p/types.zig in:root\npub const @\"Server name\" = u32;\n", .{source});
        const fixture = try w.fixture(text);
        const cursor = fixture.cursor.?;
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
        const candidate = for (result.items) |item| {
            if (std.mem.eql(u8, item.label, "Alias.@\"Server name\"")) break item;
        } else return error.MissingEscapedAutoImport;
        try testing.expect(candidate.import_edit == null);
        const current = (try r.ctx.get(database.syntax.SourceText, cursor.file)).text;
        const prefix = current[candidate.replace.?.start..cursor.offset];
        try testing.expect(std.mem.startsWith(u8, prefix, "@\""));
        try testing.expect(std.mem.startsWith(u8, candidate.filter.?, prefix));
    }
}

test "auto import propagates candidate truncation" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", "const value = st<|>;");
    const std_file = (try w.add("/lib/std/std.zig", "pub const standard = u32;\npub const static_value = 1;\n")).file;
    try w.setGraph(std_file, &.{}, &.{});
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const result = try completion.complete(&r, added.file, added.cursor, .{ .max_auto_imports = 1 });
    try testing.expect(result.is_incomplete);
    var imported: usize = 0;
    for (result.items) |item| {
        if (item.filter != null) imported += 1;
    }
    try testing.expectEqual(@as(usize, 1), imported);
}

test "auto import merges direct aliases without losing target filters" {
    const cases = [_]struct { alias: []const u8, source: []const u8, target_filter: bool }{
        .{ .alias = "Renamed", .source = "pub fn main() void { _ = EdgeWidg<|>et; }", .target_filter = true },
        .{ .alias = "Renamed", .source = "pub fn main() void { _ = Renam<|>ed; }", .target_filter = false },
        .{ .alias = "@\"Renamed type\"", .source = "pub fn main() void { _ = EdgeWidg<|>et; }", .target_filter = true },
        .{ .alias = "@\"Renamed type\"", .source = "pub fn main() void { _ = @\"EdgeWidg<|>et\"; }", .target_filter = true },
    };
    for (cases) |case| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.fmt.allocPrint(w.arena.allocator(), "//- /p/main.zig module:app deps:lib=dep\nconst {s} = @import(\"lib\").EdgeWidget;\n{s}\n" ++
            "//- /dep/root.zig module:dep\npub const EdgeWidget = struct {{}};\n", .{ case.alias, case.source });
        const fixture = try w.fixture(text);
        const cursor = fixture.cursor.?;
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
        var count: usize = 0;
        for (result.items) |item| {
            try testing.expect(item.import_edit == null);
            if (!std.mem.eql(u8, item.label, case.alias)) continue;
            count += 1;
            if (case.target_filter) {
                const current = (try r.ctx.get(database.syntax.SourceText, cursor.file)).text;
                const raw = current[item.replace.?.start..cursor.offset];
                try testing.expect(std.mem.startsWith(u8, item.filter.?, raw));
                try testing.expectEqualStrings(if (raw[0] == '@') "@\"EdgeWidget\"" else "EdgeWidget", current[item.replace.?.start..item.replace.?.end]);
            } else {
                try testing.expect(std.mem.startsWith(u8, item.filter orelse item.label, "Renam"));
            }
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "auto import recovers unclosed escaped expression prefixes without consuming following source" {
    const cases = [_]struct { source: []const u8, label: []const u8 }{
        .{ .source = "pub fn main() void { _ = @\"EdgeWidg<|>", .label = "Alias.EdgeWidget" },
        .{ .source = "pub fn main() void { _ = @\"EdgeWidg<|>\n}", .label = "Alias.EdgeWidget" },
        .{ .source = "pub fn main() void { _ = @\"EdgeWidg<|>; }", .label = "Alias.EdgeWidget" },
        .{ .source = "pub fn main() void { const value: @\"EdgeWidg<|>\n = .{}; _ = value; }", .label = "Alias.EdgeWidget" },
        .{ .source = "pub fn main() void { _ = @\"Server na<|>", .label = "Alias.@\"Server name\"" },
        .{ .source = "pub fn main() void { _ = @\"S\\x65rver na<|>\r\n}", .label = "Alias.@\"Server name\"" },
        .{ .source = "const value = @\"S\\x65r<|>", .label = "Alias.@\"Server name\"" },
        .{ .source = "const value = @\"Uni\\u{63}<|>", .label = "Alias.Unicode" },
    };
    for (cases) |case| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        _ = try w.fixture("//- /p/main.zig module:root\n" ++
            "//- /p/types.zig in:root\npub const EdgeWidget = struct {};\npub const @\"Server name\" = u32;\npub const Unicode = u32;\n");
        const source = try std.fmt.allocPrint(w.arena.allocator(), "const Alias = @import(\"types.zig\");\n{s}", .{case.source});
        const added = try w.add("/p/main.zig", source);
        const cursor = .{ .file = added.file, .offset = added.cursor };
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
        const candidate = for (result.items) |item| {
            if (std.mem.eql(u8, item.label, case.label)) break item;
        } else return error.MissingUnclosedEscapedAutoImport;
        const current = (try r.ctx.get(database.syntax.SourceText, cursor.file)).text;
        const range = candidate.replace.?;
        try testing.expectEqual(cursor.offset, range.end);
        try testing.expect(std.mem.startsWith(u8, current[range.start..range.end], "@\""));
        try testing.expect(std.mem.indexOfAny(u8, current[range.start..range.end], "\r\n") == null);
        try testing.expect(std.mem.startsWith(u8, candidate.filter.?, current[range.start..cursor.offset]));
        try testing.expect(candidate.import_edit == null);
    }
}

test "auto import unclosed escaped recovery preserves non-reference contexts and incomplete escapes" {
    const sources = [_][]const u8{
        "const @\"EdgeWidg<|>",
        "fn @\"EdgeWidg<|>",
        "const value = object.@\"EdgeWidg<|>",
        "const value = .@\"EdgeWidg<|>",
        "const value = error.@\"EdgeWidg<|>",
        "pub fn main() void { break :@\"EdgeWidg<|>",
        "pub fn main() void { for (items) |@\"EdgeWidg<|>",
        "const value = \"EdgeWidg<|>",
        "const value = 'E<|>",
        "// @\"EdgeWidg<|>",
        "const value = @import(\"EdgeWidg<|>",
        "const value = @EdgeWidg<|>",
        "const value = @\"EdgeWidg\\<|>",
        "const value = @\"EdgeWidg\\x6<|>",
        "const value = @\"EdgeWidg\\u{6<|>",
        "const value = @\"EdgeWidg\\q<|>",
    };
    for (sources) |source| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.fmt.allocPrint(w.arena.allocator(), "//- /p/main.zig module:root\n{s}\n" ++
            "//- /p/types.zig in:root\npub const EdgeWidget = struct {{}};\n", .{source});
        const fixture = try w.fixture(text);
        const cursor = fixture.cursor.?;
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
        for (result.items) |item| {
            try testing.expect(item.import_edit == null);
            // Only the names in scope at a quoted reference (`value` itself) are filtered by their
            // quoted spelling
            try testing.expect(item.filter == null or std.mem.eql(u8, item.label, "value"));
        }
    }
}

test "auto import keeps distinct origins with the same completion label" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const fixture = try w.fixture(
        \\//- /p/main.zig module:app
        \\const value = Widg<|>;
        \\//- /p/First.zig in:app
        \\pub const Widget = struct { tag: u8 };
        \\//- /p/Second.zig in:app
        \\pub const Widget = struct { tag: u16 };
    );
    const cursor = fixture.cursor.?;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
    var origins = [2]bool{ false, false };
    var choices: usize = 0;
    for (result.items) |item| {
        if (!std.mem.eql(u8, item.label, "Widget")) continue;
        const edit = item.import_edit orelse continue;
        choices += 1;
        if (std.mem.indexOf(u8, edit.text, "@import(\"First.zig\").Widget") != null) origins[0] = true;
        if (std.mem.indexOf(u8, edit.text, "@import(\"Second.zig\").Widget") != null) origins[1] = true;
    }
    try testing.expectEqual(@as(usize, 2), choices);
    try testing.expect(origins[0] and origins[1]);
}

test "auto import refreshes shared alias prefixes before filtering diverges" {
    const cases = [_]struct { prefix: []const u8, incomplete: bool }{
        .{ .prefix = "Widg", .incomplete = true },
        .{ .prefix = "WidgetA", .incomplete = false },
        .{ .prefix = "WidgetT", .incomplete = false },
    };
    for (cases) |case| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.fmt.allocPrint(w.arena.allocator(), "//- /p/main.zig module:app deps:lib=dep\nconst Lib = @import(\"lib\");\n" ++
            "const WidgetAlias = Lib.WidgetThing;\nconst value = {s}<|>;\n" ++
            "//- /dep/root.zig module:dep\npub const WidgetThing = struct {{}};\n", .{case.prefix});
        const fixture = try w.fixture(text);
        const cursor = fixture.cursor.?;
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
        try testing.expectEqual(case.incomplete, result.is_incomplete);
        var count: usize = 0;
        for (result.items) |item| {
            if (!std.mem.eql(u8, item.label, "WidgetAlias")) continue;
            count += 1;
            try testing.expect(item.import_edit == null);
            try testing.expect(std.mem.startsWith(u8, item.filter.?, case.prefix));
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "visible completion precedes auto-import candidates" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const fixture = try w.fixture(
        \\//- /p/main.zig module:app deps:lib=dep
        \\fn main() void { const item = 1; _ = it<|>em; }
        \\//- /dep/root.zig module:dep
        \\pub const itemized = u32;
    );
    const cursor = fixture.cursor.?;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const result = try completion.complete(&r, cursor.file, cursor.offset, .{});
    var visible_at: ?usize = null;
    var auto_at: ?usize = null;
    for (result.items, 0..) |item, i| {
        if (item.filter == null and std.mem.eql(u8, item.label, "item")) visible_at = i;
        if (item.filter) |filter| {
            if (std.mem.eql(u8, filter, "itemized")) auto_at = i;
        }
    }
    try testing.expect(visible_at != null and auto_at != null);
    try testing.expect(visible_at.? < auto_at.?);
}

/// All instances (`seed.allInstances`) of the member named `name` in `file`
fn allInstancesOf(w: *World, file: FileId, name: []const u8) !struct { count: usize, complete: bool } {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(w, &ctx);
    const tree = try r.itemTree(file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.name) |n| if (std.mem.eql(u8, n, name)) break @intCast(i);
    } else return error.NoItem;
    const all = try seed.allInstances(&r, file, item);
    return .{ .count = all.insts.len, .complete = all.complete };
}

test "all instances follow generic callers to a fixpoint without depth or count limits" {
    // Prevents truncation by depth or count: concrete calls after 7 levels of generic callers,
    // mutually recursive generic functions and 70 distinct instances must all be found
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(testing.allocator,
        \\fn leaf(x: anytype) void {
        \\    _ = x;
        \\}
        \\fn l1(x: anytype) void { leaf(x); }
        \\fn l2(x: anytype) void { l1(x); }
        \\fn l3(x: anytype) void { l2(x); }
        \\fn l4(x: anytype) void { l3(x); }
        \\fn l5(x: anytype) void { l4(x); }
        \\fn l6(x: anytype) void { l5(x); }
        \\fn l7(x: anytype) void { l6(x); }
        \\fn ping(comptime T: type, n: u32) void { if (n > 0) pong(T, n - 1); }
        \\fn pong(comptime T: type, n: u32) void { if (n > 0) ping(T, n - 1); }
        \\fn many(x: anytype) void {
        \\    _ = x;
        \\}
        \\fn main() void {
        \\    l7(@as(u8, 1));
        \\    l7(@as(u16, 1));
        \\    ping(u32, 3);
        \\
    );
    defer text.deinit(testing.allocator);
    for (1..71) |k| try text.print(testing.allocator, "    many(@as([{d}]u8, undefined));\n", .{k});
    try text.appendSlice(testing.allocator, "}\n");
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text.items)).file;
    const leaf = try allInstancesOf(&w, file, "leaf");
    try testing.expectEqual(2, leaf.count);
    try testing.expect(leaf.complete);
    const pong = try allInstancesOf(&w, file, "pong");
    try testing.expectEqual(1, pong.count);
    try testing.expect(pong.complete);
    const many = try allInstancesOf(&w, file, "many");
    try testing.expectEqual(70, many.count);
    try testing.expect(many.complete);
}

test "all instances of unboundedly growing instantiations are reported incomplete" {
    // Prevents truncated instances from being taken as all of them: `grow(T)` calls `other(?T)` and
    // `other(T)` calls `grow(T)` again, so the instances grow without bound
    const text =
        \\fn grow(comptime T: type) void {
        \\    other(?T);
        \\}
        \\fn other(comptime T: type) void {
        \\    grow(T);
        \\}
        \\fn main() void {
        \\    grow(u8);
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    const grow = try allInstancesOf(&w, file, "grow");
    try testing.expect(!grow.complete);
}

test "all instances include anytype calls in files that do not import the method" {
    // Prevents looking for callers only in files that import the method's file: `c.zig` does not
    // import `a.zig` and calls its generic method through an anytype value (a pointer to `S`; the
    // type flow only recognizes instances whose argument type is exactly `S`)
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = (try w.add("/p/a.zig", "pub const S = struct {\n    pub fn foo(self: *S, comptime n: u8) void {\n        _ = self;\n        _ = n;\n    }\n};\n")).file;
    const c = (try w.add("/p/c.zig", "pub fn call(x: anytype) void {\n    x.foo(3);\n}\n")).file;
    const main = (try w.add("/p/main.zig", "const a = @import(\"a.zig\");\nconst c = @import(\"c.zig\");\npub fn main() void {\n    var s: a.S = .{};\n    c.call(&s);\n}\n")).file;
    try w.setGraph(null, &.{.{ .root = main, .imports = &.{} }}, &.{
        .{ .file = main, .module = 0, .compile = 0 },
        .{ .file = a, .module = 0, .compile = 0 },
        .{ .file = c, .module = 0, .compile = 0 },
    });
    const all = try allInstancesOf(&w, a, "foo");
    try testing.expectEqual(1, all.count);
    try testing.expect(all.complete);
}

test "all instances of targets in different files share the callers inside generic functions" {
    // Prevents looking up the callers of `call` (in a file that imports neither target) inside
    // generic functions again for every target file
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = (try w.add("/p/a.zig", "pub const S = struct {\n    pub fn run(self: *S, comptime n: u8) void {\n        _ = self;\n        _ = n;\n    }\n};\n")).file;
    const b = (try w.add("/p/b.zig", "pub const T = struct {\n    pub fn run(self: *T, comptime n: u8) void {\n        _ = self;\n        _ = n;\n    }\n};\n")).file;
    const c = (try w.add("/p/c.zig", "pub fn call(x: anytype) void {\n    x.run(3);\n}\n")).file;
    const main = (try w.add("/p/main.zig", "const a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\nconst c = @import(\"c.zig\");\npub fn main() void {\n    var s: a.S = .{};\n    var t: b.T = .{};\n    c.call(&s);\n    c.call(&t);\n}\n")).file;
    try w.setGraph(null, &.{.{ .root = main, .imports = &.{} }}, &.{
        .{ .file = main, .module = 0, .compile = 0 },
        .{ .file = a, .module = 0, .compile = 0 },
        .{ .file = b, .module = 0, .compile = 0 },
        .{ .file = c, .module = 0, .compile = 0 },
    });
    const in_a = try allInstancesOf(&w, a, "run");
    try testing.expectEqual(1, in_a.count);
    try testing.expect(in_a.complete);
    // Only those of `T.run` itself are new
    const before = w.db.executions(seed.GenericCallers);
    const in_b = try allInstancesOf(&w, b, "run");
    try testing.expectEqual(1, in_b.count);
    try testing.expect(in_b.complete);
    try testing.expectEqual(before + 1, w.db.executions(seed.GenericCallers));
}

test "callsite seeding uses an iteration of a loop over a comptime list of values" {
    // The loop variable has a type but no value (the loop is over a comptime-known list of values):
    // the instance of `PT` used to be unresolvable
    const labels = try completionLabels(
        \\const Help = struct {
        \\    v: []const u8,
        \\    pub fn value(h: Help) []const u8 {
        \\        return h.v;
        \\    }
        \\};
        \\fn Param(comptime Id: type) type {
        \\    return struct { id: Id, takes: enum { none, one } };
        \\}
        \\fn PT(comptime Id: type, comptime param: Param(Id)) type {
        \\    return switch (param.takes) {
        \\        .none => void,
        \\        .one => @TypeOf(param.id.<|>),
        \\    };
        \\}
        \\fn Args(comptime Id: type, comptime params: []const Param(Id)) type {
        \\    var t: type = void;
        \\    for (params) |param| t = PT(Id, param);
        \\    return t;
        \\}
        \\const ps = [_]Param(Help){ .{ .id = .{ .v = "a" }, .takes = .none }, .{ .id = .{ .v = "b" }, .takes = .one } };
        \\const A = Args(Help, &ps);
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("v value", labels);
}

test "a field name sliced from a comptime string in an inline for over pointers resolves @field" {
    // Pointer captures used to have no value in per-iteration inference, and neither did
    // comptime-known slices, dereferences and address-of expressions: `@field` could not resolve
    // the field
    const labels = try completionLabels(
        \\const Names = struct {
        \\    long: []const u8,
        \\    fn longest(names: *const Names) []const u8 {
        \\        return names.long;
        \\    }
        \\};
        \\const P = struct { names: Names, many: bool };
        \\const L = struct {
        \\    pub fn append(_: *L) void {}
        \\};
        \\const Args = struct { aa: u8 = 0, list: L = .{} };
        \\const ps = [_]P{ .{ .names = .{ .long = "aa" }, .many = false }, .{ .names = .{ .long = "list" }, .many = true } };
        \\fn parse(comptime params: []const P) void {
        \\    var arguments: Args = .{};
        \\    inline for (params) |*param| {
        \\        const longest = comptime param.names.longest();
        \\        const name = longest[0..longest.len].*;
        \\        if (param.many) @field(arguments, &name).<|>;
        \\    }
        \\}
        \\pub fn main() void {
        \\    parse(&ps);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("append", labels);
}

test "an iteration that leaves the loop before a declaration is not used for it" {
    // The first iteration leaves the loop at `.none => continue`: that iteration used to be taken,
    // and `F` was shown as noreturn
    const text =
        \\const P = struct { kind: enum { none, one }, T: type };
        \\fn Make(comptime ps: []const P) type {
        \\    var t: type = void;
        \\    for (ps) |p| {
        \\        const F = switch (p.kind) {
        \\            .none => continue,
        \\            .one => p.T,
        \\        };
        \\        t = F;
        \\    }
        \\    return t;
        \\}
        \\const ps = [_]P{ .{ .kind = .none, .T = u16 }, .{ .kind = .one, .T = u8 } };
        \\const M = Make(&ps);
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = (try hover.hover(&r, added.file, @intCast(std.mem.indexOf(u8, text, "F =").?), &.{}, .list)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst F: type = u8\n```\n\ninferred from iteration 2 of the loop at main.zig:4", info.text);
}

test "hover on a capture read through a container in the body shows the value of the chosen iteration" {
    // Prevents the capture read by the container from staying unknown in the iteration hover
    // infers (`p_via` was shown as the abstract `T`); expected values are the results of zig 0.17.0
    // and 0.17.1
    const text =
        \\pub fn g() void {
        \\    inline for (.{ u8, u16 }) |T| {
        \\        const S = struct {
        \\            pub const t = T;
        \\            pub const u = ?T;
        \\        };
        \\        const p_via = S.t;
        \\        const p_opt = S.u;
        \\        _ = .{ p_via, p_opt };
        \\    }
        \\}
        \\const P = union(enum) { a: u8, b: u16 };
        \\pub fn h(p: P) void {
        \\    switch (p) {
        \\        inline else => |q| {
        \\            const W = struct {
        \\                const Q = @TypeOf(q);
        \\            };
        \\            const p_payload = W.Q;
        \\            _ = p_payload;
        \\        },
        \\    }
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "p_via =", "```zig\nconst p_via: type = u8\n```\n\ninferred from iteration 1 of the loop at main.zig:2" },
        .{ "p_opt =", "```zig\nconst p_opt: type = ?u8\n```\n\ninferred from iteration 1 of the loop at main.zig:2" },
        .{ "p_payload =", "```zig\nconst p_payload: type = u8\n```\n\ninferred from iteration 1 of the loop at main.zig:14" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "hover in nested inline loops takes an iteration of each enclosing loop" {
    // Prevents leaving the loop variables of the enclosing loops abstract in the body of an inner
    // loop. zig 0.17.0 and 0.17.1 analyze that body once per combination of iterations: `direct`
    // and `via` are u8, u8, u16 and u16, `arr` [1]u8, [2]u8, [1]u16 and [2]u16, `P` starts with
    // `u8, i32, [1]u8`, `W` u8 and u16, `B` [1]u8, [3]u8, [4]u16 and [6]u16, `L` [1]u8, [1]u16,
    // [2]u8 and [2]u16.
    const text =
        \\pub fn nested() void {
        \\    inline for (.{ u8, u16 }) |T| {
        \\        inline for (.{ 1, 2 }) |c| {
        \\            const direct = T;
        \\            const N = struct {
        \\                const t = T;
        \\            };
        \\            const via = N.t;
        \\            const arr = [c]T;
        \\            _ = .{ direct, via, arr };
        \\        }
        \\        const outer = T;
        \\        _ = outer;
        \\    }
        \\}
        \\pub fn three() void {
        \\    inline for (.{ u8, u16 }) |T| {
        \\        inline for (.{ i32, i64 }) |U| {
        \\            inline for (.{ 1, 2 }) |c| {
        \\                const P = struct { T, U, [c]u8 };
        \\                _ = P;
        \\            }
        \\        }
        \\    }
        \\}
        \\pub fn prong(x: enum { a, b }) void {
        \\    inline for (.{ u8, u16 }) |T| {
        \\        switch (x) {
        \\            inline else => |v| {
        \\                const W = T;
        \\                _ = .{ W, v };
        \\            },
        \\        }
        \\    }
        \\}
        \\pub fn counted() void {
        \\    comptime var acc: usize = 0;
        \\    inline for (.{ u8, u16 }) |T| {
        \\        inline for (.{ 1, 2 }) |c| {
        \\            acc += c;
        \\            const B = [acc]T;
        \\            _ = B;
        \\        }
        \\    }
        \\}
        \\pub fn lengths() void {
        \\    inline for (.{ 1, 2 }) |n| {
        \\        inline for (.{ u8, u16 }) |E| {
        \\            const L = [n]E;
        \\            _ = L;
        \\        }
        \\    }
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "direct =", "```zig\nconst direct: type = u8\n```\n\ninferred from iteration 1 of the loop at main.zig:2 and iteration 1 of the loop at main.zig:3" },
        .{ "via =", "```zig\nconst via: type = u8\n```\n\ninferred from iteration 1 of the loop at main.zig:2 and iteration 1 of the loop at main.zig:3" },
        .{ "arr =", "```zig\nconst arr: type = [1]u8\n```\n\ninferred from iteration 1 of the loop at main.zig:2 and iteration 1 of the loop at main.zig:3" },
        .{ "outer =", "```zig\nconst outer: type = u8\n```\n\ninferred from iteration 1 of the loop at main.zig:2" },
        .{ "P =", "```zig\nconst P: type = struct { u8, i32, [1]u8 }\n```\n\ninferred from iteration 1 of the loop at main.zig:17, iteration 1 of the loop at main.zig:18 and iteration 1 of the loop at main.zig:19" },
        .{ "W =", "```zig\nconst W: type = u8\n```\n\ninferred from iteration 1 of the loop at main.zig:27" },
        .{ "B =", "```zig\nconst B: type = [1]u8\n```\n\ninferred from iteration 1 of the loop at main.zig:38 and iteration 1 of the loop at main.zig:39" },
        .{ "L =", "```zig\nconst L: type = [1]u8\n```\n\ninferred from iteration 1 of the loop at main.zig:47 and iteration 1 of the loop at main.zig:48" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
}
test "hover in an inline loop over the fields of an enclosing loop variable" {
    // Prevents unrolling the inner loop with the outer loop variable abstract: its list depends on
    // it. zig 0.17.0 and 0.17.1 give `F` u8, bool and i32.
    const text =
        \\const S1 = struct { a: u8, b: bool };
        \\const S2 = struct { x: i32 };
        \\pub fn fields() void {
        \\    inline for (.{ S1, S2 }) |S| {
        \\        inline for (@typeInfo(S).@"struct".field_types) |F0| {
        \\            const F = F0;
        \\            _ = F;
        \\        }
        \\    }
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    // `@typeInfo(S).@"struct".field_types` is read from `std.builtin.Type`
    try useRealStd(&w);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "F =").?), &.{}, .list) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst F: type = u8\n```\n\ninferred from iteration 1 of the loop at main.zig:4 and iteration 1 of the loop at main.zig:5", info.text);
}
test "references through the loop variable of an enclosing inline loop" {
    // `T.tag` in the inner loop body is `A.tag` in the first iteration of the outer loop: the
    // inner body is searched in each combination of iterations, not with `T` abstract
    const text =
        \\const A = struct {
        \\    pub const tag = 1;
        \\};
        \\const B = struct {
        \\    pub const tag = 2;
        \\};
        \\pub fn main() void {
        \\    inline for (.{ A, B }) |T| {
        \\        inline for (.{ 1, 2 }) |c| {
        \\            _ = T.tag + c;
        \\        }
        \\    }
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const fs: [1]FileId = .{file};
    for ([_][]const u8{ "tag = 1", "tag = 2" }) |decl| {
        const def = (try definition.defAt(&r, file, @intCast(std.mem.indexOf(u8, text, decl).?))) orelse return error.NoDefinition;
        const refs = try search.findReferences(&r, def, .{ .scope = &fs });
        const use = std.mem.indexOf(u8, text, "T.tag").? + 2;
        for (refs) |ref| {
            if (ref.start == use) break;
        } else {
            std.debug.print("no reference at `T.tag` for `{s}`\n", .{decl});
            return error.MissingReference;
        }
    }
}
test "try on a call whose error set depends on an abstract parameter gives the payload type" {
    // When the error set `B.Error` could not be resolved, the whole `Error!Event` used to be
    // unknown, and the result of `try` had no type
    const labels = try completionLabels(
        \\const Event = struct { kind: u8 };
        \\fn Cursor(comptime B: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        const Error = B.Error;
        \\        fn peek(self: *Self) Error!Event {
        \\            _ = self;
        \\            return .{ .kind = 0 };
        \\        }
        \\        fn f(self: *Self) Error!void {
        \\            const event = try self.peek();
        \\            _ = event.<|>;
        \\        }
        \\    };
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("kind", labels);
}

test "@hasField on anonymous struct types decides branches in generic bodies" {
    // `@hasField` on anonymous structs used to be unresolvable: the branch was not judged inactive,
    // the instance in which `opt` has no `other` was chosen, and completion was empty
    const labels = try completionLabels(
        \\const A = struct {
        \\    pub const opts = .{};
        \\};
        \\const B = struct {
        \\    pub const opts = .{ .other = "x" };
        \\};
        \\fn g(comptime T: type) void {
        \\    const opt = comptime T.opts;
        \\    if (@hasField(@TypeOf(opt), "other")) {
        \\        _ = opt.<|>;
        \\    }
        \\}
        \\pub fn main() void {
        \\    g(A);
        \\    g(B);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("other", labels);
}

test "callsite seeding uses each value of an inline switch prong" {
    // The capture of `inline 0...1 => |index|` is instantiated separately for each value: it used
    // to be inferred as unknown, so the instance of `read(T, names[index])` could not be resolved
    const labels = try completionLabels(
        \\const S = struct {
        \\    a: struct { x: u8 },
        \\    b: struct { y: u8 },
        \\};
        \\fn readField(comptime name: []const u8) void {
        \\    var v: @FieldType(S, name) = undefined;
        \\    _ = v.<|>;
        \\}
        \\const names = [_][]const u8{ "a", "b" };
        \\pub fn main() void {
        \\    var found: usize = 1;
        \\    _ = &found;
        \\    switch (found) {
        \\        inline 0...1 => |index| readField(names[index]),
        \\        else => {},
        \\    }
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("x", labels);
}

test "dereferencing a C pointer gives its child type" {
    // Dereferencing the `[*c]T` generated by translate-c used to give unknown: none of the members
    // after `face.*.glyph.*.bitmap` could be resolved
    const labels = try completionLabels(
        \\const Bitmap = extern struct { width: c_uint, rows: c_uint };
        \\const GlyphRec = extern struct { bitmap: Bitmap };
        \\const FaceRec = extern struct { glyph: [*c]GlyphRec };
        \\fn f(face: [*c]FaceRec) void {
        \\    const glyph = face.*.glyph;
        \\    const bitmap = glyph.*.bitmap;
        \\    _ = bitmap.<|>;
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("width rows", labels);
}

test "types defined inside an inline for take the loop variable of each iteration" {
    // The field types of a struct defined in the loop body depend on the loop variable: if types do
    // not distinguish iterations, the field types cannot be resolved, and neither can `@hasField`
    const labels = try completionLabels(
        \\const A = struct { a_field: u8 };
        \\const B = struct { b_field: u8 };
        \\fn read(comptime T: type) void {
        \\    if (@hasField(T, "inner")) {
        \\        var v: @FieldType(T, "inner") = undefined;
        \\        _ = v.<|>;
        \\    }
        \\}
        \\pub fn main() void {
        \\    inline for (.{ A{ .a_field = 0 }, B{ .b_field = 0 } }) |value| {
        \\        const V = @TypeOf(value);
        \\        const Wrapper = struct { inner: V };
        \\        read(Wrapper);
        \\    }
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("a_field", labels);
}

test "an iteration of an inline for sees comptime vars as the earlier iterations left them" {
    // In iteration n, a `comptime var` has the value as modified by the first n iterations: it used
    // to have no value, so `items[i]` could not be resolved
    const labels = try completionLabels(
        \\const A = struct { a_field: u8 };
        \\const B = struct { b_field: u8 };
        \\const kinds = [_]bool{ false, true, false, true };
        \\fn read(items: struct { A, B }) void {
        \\    comptime var index = 0;
        \\    inline for (kinds) |positional| {
        \\        if (!positional) continue;
        \\        const i = index;
        \\        index += 1;
        \\        if (i == 1) {
        \\            const item = items[i];
        \\            _ = item.<|>;
        \\        }
        \\    }
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("b_field", labels);
}

test "comptime vars follow assignments in straight-line code" {
    const labels = try completionLabels(
        \\const A = struct { a_field: u8 };
        \\const B = struct { b_field: u8 };
        \\fn f(items: struct { A, B }) void {
        \\    comptime var i = 0;
        \\    i += 1;
        \\    _ = items[i].<|>;
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("b_field", labels);
}

test "an inline for over an undefined array in a generic body counts its elements" {
    // In an abstract instance the array's value is `undefined`, and so is each element: iterations
    // used to be counted by whether elements have a value, so the count never reached the end and
    // overflowed
    const labels = try completionLabels(
        \\const S = struct { a_field: u8 };
        \\fn f(comptime T: type) void {
        \\    const list: [2]T = undefined;
        \\    inline for (list) |x| {
        \\        _ = x.<|>;
        \\    }
        \\}
        \\pub fn main() void {
        \\    f(S);
        \\}
        \\
    );
    defer testing.allocator.free(labels);
    try testing.expectEqualStrings("a_field", labels);
}

test "hover never treats the initializer as the missing type of a declaration" {
    // `const T2: = u32;` lacks its type: it must not be shown as a value of type `u32`
    const text = "const T2: = u32;\nconst z = T2;\nconst w: T2 = 1;\ntest { _ = .{ T2, z, w }; }\n";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "T2, z", "```zig\nconst T2: type = u32\n```" },
        .{ "z, w", "```zig\nconst z: type = u32\n```" },
        .{ "w }", "```zig\nconst w: u32 = 1\n```" },
    };
    for (cases) |c| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const added = try w.add("/p/main.zig", text);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r = resolver(&w, &ctx);
        const offset: u32 = @intCast(std.mem.lastIndexOf(u8, text, c[0]).?);
        const info = try hover.hover(&r, added.file, offset, &.{}, .list) orelse return error.NoHover;
        try testing.expectEqualStrings(c[1], info.text);
    }
}

test "enum literal completion above a line that starts with `.name`" {
    // `zig fmt` puts each `.name = value,` and `.tag => ...,` on its own line: a `.` typed above
    // one must not join it into a field access, which leaves the completion empty
    const s = "const S = struct { a: u32 = 0, b: u32 = 0, c: u32 = 0, d: u32 = 0 };\n";
    const color = "const Color = enum { red, green, blue };\nfn paint(c: Color, d: Color) void { _ = .{ c, d }; }\n";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ s ++ "fn f() void {\n    const s: S = .{\n        .a = 1,\n        .<|>\n        .b = 2,\n    };\n    _ = s;\n}\n", "c d" },
        .{ s ++ "fn f() void {\n    const s: S = .{\n        .<|>\n        .a = 1,\n    };\n    _ = s;\n}\n", "b c d" },
        .{ s ++ "fn f() void {\n    const s: S = .{\n        .a = 1,\n        .c<|>\n        .b = 2,\n    };\n    _ = s;\n}\n", "c d" },
        .{ color ++ "fn f(c: Color) void {\n    switch (c) {\n        .<|>\n        .blue => {},\n    }\n}\n", "red green blue" },
        .{ color ++ "fn f(c: Color) void {\n    switch (c) {\n        .red,\n        .<|>\n        .blue,\n        => {},\n    }\n}\n", "red green blue" },
        .{ color ++ "fn f(c: Color) void {\n    switch (c) {\n        .r<|>\n        .blue => {},\n    }\n}\n", "red green blue" },
        .{ color ++ "fn f() void {\n    paint(\n        .<|>\n        .blue,\n    );\n}\n", "red green blue" },
        .{ color ++ "const T = struct { a: Color = .red, d: Color = .red };\nfn f() void {\n    const t: T = .{\n        .d = .<|>\n        .a = .red,\n    };\n    _ = t;\n}\n", "red green blue" },
        .{ color ++ "const T = struct { a: Color = .red, d: Color = .red };\nfn f() void {\n    const t: T = .{\n        .d = .g<|>\n        .a = .red,\n    };\n    _ = t;\n}\n", "red green blue" },
    };
    for (cases) |c| {
        const labels = try completionLabels(c[0]);
        defer testing.allocator.free(labels);
        testing.expectEqualStrings(c[1], labels) catch |err| {
            std.debug.print("completion in `{s}`\n", .{c[0]});
            return err;
        };
    }
    for ([_][]const u8{ ".<|>", ".m<|>" }) |typed| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.mem.concat(w.arena.allocator(), u8, &.{ ".{\n    .name = .demo,\n    ", typed, "\n    .dependencies = .{},\n}\n" });
        const at = try w.add("/p/build.zig.zon", text);
        try testing.expectEqualStrings("fingerprint version minimum_zig_version paths", try completionAt(&w, at));
    }
}

test "member completion offers methods taking a pointer on variables reached through namespaces" {
    // `State.c` and the payload pointer of `&(x orelse return)` used to be treated as constant,
    // which hid the methods receiving `*T`
    const ns_labels = try completionLabels(
        \\const Counter = struct {
        \\    n: u32 = 0,
        \\    pub fn inc(self: *Counter) void {
        \\        self.n += 1;
        \\    }
        \\    pub fn get(self: *const Counter) u32 {
        \\        return self.n;
        \\    }
        \\};
        \\const State = struct {
        \\    pub var c: Counter = .{};
        \\};
        \\fn probe() void {
        \\    State.c.<|>
        \\}
        \\
    );
    defer testing.allocator.free(ns_labels);
    try testing.expectEqualStrings("n inc get", ns_labels);
    const payload_labels = try completionLabels(
        \\const Sym = struct {
        \\    file: ?u32 = null,
        \\    fn close(d: *Sym) void {
        \\        d.file = null;
        \\    }
        \\};
        \\const Obj = struct {
        \\    d_sym: ?Sym = null,
        \\    fn closeDebugInfo(self: *Obj) bool {
        \\        const d_sym = &(self.d_sym orelse return false);
        \\        d_sym.<|>
        \\        return true;
        \\    }
        \\};
        \\
    );
    defer testing.allocator.free(payload_labels);
    try testing.expectEqualStrings("file close", payload_labels);
}

test "enum literals compared with an enum or in branches without a result type offer only tags" {
    // A comparison operand has no result type, so it cannot be a decl literal: `mode == .` used
    // to offer the declarations of the enum, which fail to compile there
    const prefix =
        \\const Optimize = enum {
        \\    debug,
        \\    safe,
        \\    pub const Debug: Optimize = .debug;
        \\};
        \\var mode: Optimize = .debug;
        \\fn probe(flag: bool) void {
        \\
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "    if (mode == .<|>) {}\n", "debug safe" },
        .{ "    if (mode != .<|>) {}\n", "debug safe" },
        .{ "    if (.<|> == mode) {}\n", "debug safe" },
        .{ "    const o = if (flag) mode else .<|>;\n    _ = o;\n", "debug safe" },
        // With a result type, decl literals are offered
        .{ "    const m: Optimize = .<|>;\n    _ = m;\n", "debug safe Debug" },
        .{ "    switch (mode) {\n        .<|> => {},\n        else => {},\n    }\n", "debug safe Debug" },
    };
    for (cases) |c| {
        const text = try std.mem.concat(testing.allocator, u8, &.{ prefix, c[0], "    _ = flag;\n}\n" });
        defer testing.allocator.free(text);
        const labels = try completionLabels(text);
        defer testing.allocator.free(labels);
        testing.expectEqualStrings(c[1], labels) catch |err| {
            std.debug.print("completion in `{s}`\n", .{c[0]});
            return err;
        };
    }

    // `.debug` in a comparison still refers to the tag; `.Debug` refers to nothing
    const text =
        \\const Optimize = enum {
        \\    debug,
        \\    safe,
        \\    pub const Debug: Optimize = .debug;
        \\};
        \\var mode: Optimize = .debug;
        \\fn probe() bool {
        \\    return mode == .debug or mode == .Debug;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const tag = (try definition.definition(&r, file, @intCast(std.mem.indexOf(u8, text, ".debug or").? + 1))) orelse return error.NoDefinition;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "debug,").?)), tag.start);
    try testing.expectEqual(@as(?definition.Target, null), try definition.definition(&r, file, @intCast(std.mem.indexOf(u8, text, ".Debug;\n}").? + 1)));
}

test "hover on a reference in a coercing context shows its own type" {
    // A result type coerces the value, not the reference: hover used to show the coerced type
    // (`const a: ?u8` for `a` passed to a `?u8` parameter)
    const text =
        \\const Color = enum {
        \\    red,
        \\    green,
        \\    pub const default: Color = .red;
        \\};
        \\const K = struct {
        \\    const G2: u8 = 2;
        \\};
        \\const S = struct { x: u32 };
        \\fn Box(comptime T: type) type {
        \\    return struct { v: T };
        \\}
        \\fn take(o: ?u8) void {
        \\    _ = o;
        \\}
        \\fn r(y: u64) ?u16 {
        \\    return @intCast(y);
        \\}
        \\fn g(p: u8) ?u8 {
        \\    return p;
        \\}
        \\fn probe(s: S, box: Box(u8)) void {
        \\    const a: u8 = 5;
        \\    take(a);
        \\    const b: u8 = a;
        \\    const v: ?u32 = s.x;
        \\    const c: ?Color = .red;
        \\    const d: ?Color = .default;
        \\    const e: ?u8 = K.G2;
        \\    const n = 5;
        \\    const x8: u8 = n;
        \\    take(box.v);
        \\    take(null);
        \\    _ = .{ b, v, c, d, e, x8, r, g };
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "a);", "```zig\nconst a: u8 = 5\n```" },
        .{ "a;\n", "```zig\nconst a: u8 = 5\n```" },
        .{ "p;", "```zig\np: u8\n```" },
        .{ "x;", "```zig\nx: u32\n```" },
        .{ "red;\n    const d", "```zig\nred: Color = .red\n```" },
        .{ "default;\n    const e", "```zig\nconst default: Color = .red\n```" },
        .{ "G2;\n    const n", "```zig\nconst G2: u8 = 2\n```" },
        .{ "n;", "```zig\nconst n: comptime_int = 5\n```" },
        .{ "v);", "```zig\nv: u8\n```" },
        .{ "null)", "```zig\n?u8 = null\n```" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
    // A cast takes its result type without the optional
    const cast = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "@intCast").?), &.{}, .list) orelse return error.NoHover;
    try testing.expect(std.mem.endsWith(u8, cast.text, "Inferred result:\n\n```zig\nu16\n```"));
}

test "captures of inline prongs on tagged unions take the payload of each item" {
    // An inline prong is instantiated for each item: its capture used to be the peer of all
    // payloads (`i64` for `u8` and `i64`), or unknown for structs, so their fields did not resolve
    const text =
        \\const A = struct { x: u8 };
        \\const B = struct { x: i64 };
        \\const U = union(enum) { a: u8, b: i64, c: void };
        \\const V = union(enum) { a: A, b: B, c: void };
        \\fn probe(u: U, v: V) void {
        \\    switch (u) {
        \\        inline .a, .b => |p| {
        \\            _ = &p;
        \\        },
        \\        else => {},
        \\    }
        \\    switch (u) {
        \\        .a, .b => |q| {
        \\            _ = &q;
        \\        },
        \\        else => {},
        \\    }
        \\    switch (v) {
        \\        inline .a, .b => |s| {
        \\            const x = s.x;
        \\            _ = &x;
        \\        },
        \\        else => {},
        \\    }
        \\    switch (v) {
        \\        .c => {},
        \\        inline else => |e| {
        \\            const y = e.x;
        \\            _ = &y;
        \\        },
        \\    }
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "p;", "```zig\np: u8\n```\n\ninferred from iteration 1 of the loop at main.zig:6" },
        .{ "q| {", "```zig\nq: i64\n```" },
        .{ "x = s.x", "```zig\nconst x: u8\n```\n\ninferred from iteration 1 of the loop at main.zig:18" },
        .{ "y = e.x", "```zig\nconst y: u8\n```\n\ninferred from iteration 1 of the loop at main.zig:25" },
    };
    for (cases) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?), &.{}, .list) orelse return error.NoHover;
        testing.expectEqualStrings(c[1], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
    // `s.x` refers to the field of each payload: `A.x` and `B.x` both find it
    const fs: [1]FileId = .{file};
    for ([_][]const u8{ "x: u8 }", "x: i64 }" }) |field| {
        const def = (try definition.defAt(&r, file, @intCast(std.mem.indexOf(u8, text, field).?))) orelse return error.NoDefinition;
        const refs = try search.findReferences(&r, def, .{ .scope = &fs });
        var at_s = false;
        var at_e = false;
        for (refs) |ref| {
            if (ref.start == std.mem.indexOf(u8, text, "s.x").? + 2) at_s = true;
            if (ref.start == std.mem.indexOf(u8, text, "e.x").? + 2) at_e = true;
        }
        testing.expect(at_s and at_e) catch |err| {
            std.debug.print("references of `{s}`\n", .{field});
            return err;
        };
    }
    const t = (try definition.definition(&r, file, @intCast(std.mem.indexOf(u8, text, "s.x").? + 2))) orelse return error.NoDefinition;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "x: u8 }").?)), t.start);
}
