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
        const info = try hover.hover(&r, file, offsetOf(c[0], c[1])) orelse return error.NoHover;
        testing.expectEqualStrings(c[2], info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
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
    try testing.expectEqualStrings("x y init dist", try std.mem.join(w.arena.allocator(), " ", labels.items));
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

    const info = (try hover.hover(&r, file, test_name)) orelse return error.NoHover;
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

    const local = (try hover.hover(&r, added.file, @intCast(std.mem.indexOf(u8, clean, "_ = @\"a b\"").? + 6))).?;
    try testing.expectEqualStrings("```zig\nconst @\"a b\": u8\n```", local.text);
    const param = (try hover.hover(&r, added.file, @intCast(std.mem.indexOf(u8, clean, "return @\"i32\"").? + 8))).?;
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
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "add(1, 2)").?)) orelse return error.NoHover;
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
    // A function in a file is Function, a method of another container is Method
    for ([_]struct { []const u8, completion.Item.Kind }{ .{ "point.negated", .method }, .{ "thing.negative", .function } }) |c| {
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
        // Functions (including function pointers) whose return value fits
        .{ "Want", "fn cd_b() Want { return .a; }", true },
        .{ "Want", "const cd_b: *const fn () Want = undefined;", true },
        // Other conversions, such as integer widening and comptime_int, do not count
        .{ "u64", "const cd_b: u32 = 0;", false },
        .{ "u32", "const cd_b = 1;", false },
        .{ "*Want", "const cd_b: *const Want = undefined;", false },
        .{ "[]u8", "const cd_b: []const u8 = undefined;", false },
        .{ "Want", "const cd_b: ?Want = .a;", false },
        .{ "Want", "fn cd_b() ?Want { return .a; }", false },
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

test "expected types are not used where the syntax tree may be wrong" {
    try expectRanked(expected_decls ++ "const cd_t = u8;\n", &.{
        // An unclosed call makes the next line recover as an error node and `Want = cd`; the type
        // of the left-hand side, `type`, is not the expected type
        .{ "fn run() void {\n    take(cd_n,\n    const x: Want = cd<|>;\n    _ = x;\n}", "cd_n cd_o cd_w cd_t" },
        // The call at the cursor is not closed; the statement has a syntax error
        .{ "fn run() void {\n    take(cd<|>\n}", "cd_n cd_o cd_w cd_t" },
        .{ "fn run() void {\n    const o: Other = .{ .w = cd<|>, .w = };\n    _ = o;\n}", "cd_n cd_o cd_w cd_t" },
        // Syntax errors in other statements do not matter, including a `;` missing from the
        // previous statement
        .{ "fn run() void {\n    const y: u8 = ;\n    const x: Want = cd<|>;\n    _ = .{ x, y };\n}", "cd_w cd_n cd_o cd_t" },
        .{ "fn run() void {\n    const y: u8 = 0\n    const x: Want = cd<|>;\n    _ = .{ x, y };\n}", "cd_w cd_n cd_o cd_t" },
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
        .{ .file = lib_file, .module = 0, .root_module = 0 },
        .{ .file = args_file, .module = 0, .root_module = 0 },
        .{ .file = main_file, .module = 0, .root_module = 0 },
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
    const param = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "k, Kind").?))).?;
    try testing.expectEqualStrings("```zig\nk: Kind\n```", param.text);
    const member = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "beta }").?))).?;
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
        .{ "pos =", "const pos = .{ .x = 1, .y = 2, .name = \"origin\", .tags = .{ .a, .b }, .inner = .{ .z = 1.5, .on = true } }" },
        .{ "x, @", "comptime_int = 1" },
        .{ "y, pos", "comptime_int = 2" },
        .{ "z, pos", "comptime_float = 1.5" },
        .{ "name }", "*const [6:0]u8 = \"origin\"" },
    };
    for (hovers) |c| {
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?)) orelse return error.NoHover;
        testing.expectEqualStrings(try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}\n```", .{c[1]}), info.text) catch |err| {
            std.debug.print("hover at `{s}`\n", .{c[0]});
            return err;
        };
    }
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
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?)) orelse return error.NoHover;
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
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?)) orelse return error.NoHover;
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
        const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?)) orelse return error.NoHover;
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
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "v =").?)) orelse return error.NoHover;
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
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "v =").?)) orelse return error.NoHover;
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
        .{ .file = other, .module = 0, .root_module = 0 },
        .{ .file = main, .module = 0, .root_module = 0 },
        .{ .file = lib, .module = 0, .root_module = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = try hover.hover(&r, lib, @intCast(std.mem.indexOf(u8, lib_text, "bigger =").?)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst bigger: i64\n```\n\ninferred from the call at main.zig:3", info.text);
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
        .{ .file = alias, .module = 0, .root_module = 0 },
        .{ .file = main, .module = 0, .root_module = 0 },
        .{ .file = lib, .module = 0, .root_module = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const info = try hover.hover(&r, lib, @intCast(std.mem.indexOf(u8, lib_text, "bigger =").?)) orelse return error.NoHover;
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
        .{ "const s: S = .<|>;", "empty init" },
        .{ "const u: U = .<|>;", "num none" },
        // The result type drops the error union and optional
        .{ "fn f() !E { return .<|>; }", "red green default parse" },
        .{ "fn f() error{X}!?U { return .<|>; }", "num none" },
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

    const info = (try hover.hover(&r, file, at("Foo;") + 1)).?;
    try testing.expectEqualStrings("```zig\nerror.Foo: error{Bar,Foo}\n```\n\nthe foo error", info.text);
    const plain = (try hover.hover(&r, file, at("Baz;") + 1)).?;
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
    const info = (try hover.hover(&r, file, at("error.Escaped") + @as(u32, "error.".len))).?;
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
        .{ "long =", "const long = .{ Alpha_Long_Name, Beta_Long_Name, Alpha_Long_Name, Beta_Long_Name, Alpha_Long_Name, Beta_Long_Name, Alpha_Long_Name, Beta_Long_Name }" },
        .{ "msg =", "const msg: *const [72:0]u8 = \"a message that is longer than sixty-four bytes, all of it shown in hover\"" },
        .{ "many =", "const many: struct { u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8, u8 }" },
        // Nested anonymous containers are expanded too; only self-references are shown as `{...}`
        .{ "in =", "const in: struct { deep: struct { z: u8 }, next: ?*const struct {...} }" },
        // `@typeName` is the full name (as in the compiler, 315 bytes)
        .{ "name_len =", "const name_len: usize = 315" },
    };
    for (cases) |c| {
        const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, c[0]).?))).?;
        testing.expectEqualStrings(try std.fmt.allocPrint(w.arena.allocator(), "```zig\n{s}\n```", .{c[1]}), info.text) catch |err| {
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
    const info = (try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "i = s.inner").?))).?;
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
    const info = try hover.hover(&r, file, @intCast(std.mem.indexOf(u8, text, "bigger =").?)) orelse return error.NoHover;
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
    try testing.expectEqualStrings("x86 arm isArm isARM", try std.mem.join(w.arena.allocator(), " ", labels.items));
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

    const x = (try hover.hover(&r, file, at_x)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nx: Foo\n```\n\ninferred from the call at main.zig:18", x.text);
    const hello = (try hover.hover(&r, file, at_hello)) orelse return error.NoHover;
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

    const x = (try hover.hover(&r, file, at_x)) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nx: unknown\n```", x.text);
    try testing.expect(try hover.hover(&r, file, at_hello) == null);
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
        .{ .file = engine_file, .module = 0, .root_module = 0 },
        .{ .file = added.file, .module = 0, .root_module = 0 },
        .{ .file = main, .module = 0, .root_module = 0 },
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
    const info = (try hover.hover(&r, added.file, @intCast(std.mem.indexOf(u8, plain, "v = ").?))) orelse return error.NoHover;
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
    try testing.expectEqualStrings("on off toBool", by_name);
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
        .{ "fn f() void {\n    const prefix = \"file://\";\n    _ = prefix.<|>;\n}\n", "len" },
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
        .{ .file = main, .module = 0, .root_module = 0 },
        .{ .file = lib, .module = 1, .root_module = 0 },
        .{ .file = other, .module = 2, .root_module = 0 },
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
            const info = try hover.hover(&r, file, at) orelse return error.NoHover;
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
        const info = try hover.hover(&r, added.file, added.cursor) orelse return error.NoHover;
        try testing.expect(std.mem.indexOf(u8, info.text, case.signature) != null);
        try testing.expect(std.mem.indexOf(u8, info.text, "https://ziglang.org/documentation/0.17.0/") != null);
        if (case.value) |value| try testing.expect(std.mem.indexOf(u8, info.text, value) != null);
        if (std.mem.indexOf(u8, case.signature, "@sizeOf") != null)
            try testing.expect(std.mem.indexOf(u8, info.text, "number of bytes") != null);
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
            try testing.expect(std.mem.indexOf(u8, item.doc.?, "0.17.0") != null);
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
        if (try hover.hover(&r, added.file, added.cursor)) |info|
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
        const info = try hover.hover(&r, added.file, added.cursor) orelse return error.NoHover;
        if (case.gap) {
            try testing.expect(std.mem.indexOf(u8, info.text, "0.17.0") != null);
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
    const cases = [_][]const u8{
        "const st<|>d = 1;",
        "fn st<|>d() void {}",
        "fn run(st<|>d: u32) void {}",
        "const S = struct { st<|>d: u32 };",
        "const value = \"st<|>d\";",
        "// st<|>d\nconst value = 1;",
        "const value = @import(\"st<|>d\");",
        "const value = object.st<|>d;",
        "const value = .st<|>d;",
        "const value = error.st<|>d;",
        "fn run() void { break :st<|>d; }",
        "const value: u3<|>2 = undefined;",
        "fn run() void { _<|> = 1; }",
        "fn run() void { <|> }",
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
        const baseline = try completion.complete(&r, added.file, added.cursor, .{ .auto_import = false });
        const result = try completion.complete(&r, added.file, added.cursor, .{});
        try testing.expect(!result.is_incomplete);
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
            try testing.expect(item.filter == null);
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
        .{ .file = main, .module = 0, .root_module = 0 },
        .{ .file = a, .module = 0, .root_module = 0 },
        .{ .file = c, .module = 0, .root_module = 0 },
    });
    const all = try allInstancesOf(&w, a, "foo");
    try testing.expectEqual(1, all.count);
    try testing.expect(all.complete);
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
    const info = (try hover.hover(&r, added.file, @intCast(std.mem.indexOf(u8, text, "F =").?))) orelse return error.NoHover;
    try testing.expectEqualStrings("```zig\nconst F: type = u8\n```\n\ninferred from iteration 2 of the loop at main.zig:4", info.text);
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
