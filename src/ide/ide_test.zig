//! 依赖类型推导的 IDE 功能测试（内存项目）。

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

const src =
    \\/// 平面上的点
    \\const Point = struct {
    \\    x: i32,
    \\    y: i32 = 0,
    \\    pub const origin: Point = .{ .x = 0 };
    \\    pub fn init(x: i32, y: i32) Point { return .{ .x = x, .y = y }; }
    \\    /// 到原点的距离
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
        .{ "dist(3)", 0, "```zig\npub fn dist(self: Point, scale: u32) u32\n```\n\n到原点的距离" },
        .{ "Point", 0, "```zig\nconst Point = struct\n```\n\n平面上的点" },
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
    // `ptr.` 之后（经由指针）：字段与方法
    const items = try completion.complete(&r, file, offsetOf("ptr.x", 0) + 4);
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    try testing.expectEqualStrings("x y init dist", try std.mem.join(w.arena.allocator(), " ", labels.items));
    try testing.expectEqualStrings("i32", items[0].detail.?);
    // 切片
    const slice_items = try completion.complete(&r, file, offsetOf("buf.len", 0) + 4);
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
    // 方法调用：跳过 self
    const m = try signature_help.signatureHelp(&r, file, offsetOf("3);", 0)) orelse return error.NoSignature;
    try testing.expectEqual(1, m.active);
    try testing.expectEqualStrings("到原点的距离", m.doc.?);

    const hints = try inlay_hints.inlayHints(&r, file, 0, @intCast(src.len), .{});
    var out: std.ArrayList(u8) = .empty;
    for (hints) |h| {
        try out.appendSlice(w.arena.allocator(), h.label);
        try out.append(w.arena.allocator(), ' ');
    }
    // 局部变量类型；调用处参数名（实参与参数同名时省略）
    try testing.expectEqualStrings("x: y: : u32 scale: : u32 a: b: ", out.items);
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
        // 元组字段不是合法标识符，以引号形式插入
        .{ "t.len", "@\"0\" @\"1\" len" },
        // 与原生类型同名的字段可以直接访问
        .{ "a.name", "name type" },
    };
    for (cases) |c| {
        const at: u32 = @intCast(std.mem.indexOf(u8, text, c[0]).? + std.mem.indexOfScalar(u8, c[0], '.').? + 1);
        const items = try completion.complete(&r, file, at);
        var labels: std.ArrayList([]const u8) = .empty;
        for (items) |it| try labels.append(w.arena.allocator(), it.label);
        testing.expectEqualStrings(c[1], try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
            std.debug.print("completion after `{s}`\n", .{c[0]});
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
    // `over` 只在泛型的 `run` 中调用：经由 `run` 的调用点实例得到具体类型
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
    // `leaf` ← 泛型的 `mid` ← 泛型的 `run` ← 具体的调用
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
    // 不导入 lib.zig 的文件即使有同名调用也不参与
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
    // 别名的别名：main.zig 中只出现 `top`，没有 `max`
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
        // 结果类型去掉 error union 与 optional
        .{ "fn f() !E { return .<|>; }", "red green default parse" },
        .{ "fn f() error{X}!?U { return .<|>; }", "num none" },
        // 带标签的 union 在类型上访问字段得到标签；不带标签的没有
        .{ "const t = U.<|>;", "num none" },
        .{ "const t = V.<|>;", "k" },
        // 没有期望类型
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
        const items = try completion.complete(&r, added.file, added.cursor);
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
    // 运行时的条件与取决于抽象参数的条件不是非活动代码
    try testing.expectEqual(2, ranges.len);
    try testing.expectEqualStrings("{\n        return x + 1;\n    }", text[ranges[0].start..ranges[0].end]);
    try testing.expectEqualStrings("x * 2", text[ranges[1].start..ranges[1].end]);
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

    // `p.` 之后：调用点实例中 `p` 为 Point
    const items = try completion.complete(&r, file, at("p.x") + 2);
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    try testing.expectEqualStrings("x scale", try std.mem.join(w.arena.allocator(), " ", labels.items));

    const t = try definition.definition(&r, file, at("scale(2)")) orelse return error.NoDefinition;
    try testing.expect(std.mem.startsWith(u8, text[t.start..], "scale(self: Point"));

    const s = try signature_help.signatureHelp(&r, file, at("2);")) orelse return error.NoSignature;
    try testing.expectEqualStrings("fn scale(self: Point, k: i32) i32", s.label);
    try testing.expectEqual(1, s.active);

    // 抽象的结果中未知的局部变量：类型取自调用点的实例，并说明所依据的调用
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
        // 标签：内层在前
        .{ "fn f() void { outer: while (true) { inner: { break :<|> } } }", "inner outer" },
        .{ "fn f() void { outer: while (true) { continue :ou<|>; } }", "outer" },
        // 初始化中未赋值的字段
        .{ "const s: S = .{ .x = 1, .<|> };", "y z" },
        .{ "const s = S{ .<|> };", "x y z" },
        .{ "const s: ?S = .{ .y = 2, .<|> };", "x z" },
        // import：模块名（没有项目时只有固定的三个）
        .{ "const a = @import(\"<|>\");", "std builtin root" },
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
        const items = try completion.complete(&r, added.file, added.cursor);
        var labels: std.ArrayList([]const u8) = .empty;
        for (items) |it| try labels.append(w.arena.allocator(), it.label);
        testing.expectEqualStrings(c[1], try std.mem.join(w.arena.allocator(), " ", labels.items)) catch |err| {
            std.debug.print("case {d}: `{s}`\n", .{ i, c[0] });
            return err;
        };
    }

    // 内置函数：替换范围从 `@` 开始，到名字末尾
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", "fn f() void {\n    _ = @imp<|>ort;\n}\n");
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = try completion.complete(&r, added.file, added.cursor);
    try testing.expectEqual(std.zig.BuiltinFn.list.keys().len, items.len);
    const import = for (items) |it| {
        if (std.mem.eql(u8, it.label, "@import")) break it;
    } else return error.NoImport;
    try testing.expectEqual(added.cursor - 4, import.replace.?.start);
    try testing.expectEqual(added.cursor + 3, import.replace.?.end);
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
        // definition 沿别名追到 Point，declaration 停在 P
        .{ definition.definition, "P = undefined", "Point = struct" },
        .{ definition.declaration, "P = undefined", "P = Point" },
        // type definition：剥去 optional 与指针；经别名的类型标注；类型名本身
        .{ definition.typeDefinition, "p = make", "Point = struct" },
        .{ definition.typeDefinition, "q: P", "Point = struct" },
        .{ definition.typeDefinition, "Point {", "Point = struct" },
        // 泛型函数返回的容器：跳到容器本身
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
    const items = try @import("completion.zig").complete(&r, file, @intCast(std.mem.indexOf(u8, text, "MissingValue or").?));
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
        \\fn f() void {
        \\    const a: u32 = 1;
        \\    const v = add(a, 2);
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
    const cases = [_]struct { inlay_hints.Options, []const u8 }{
        // 默认：类型；形参名，与实参同名的 `a` 不提示
        .{ .{}, ": u32 b:" },
        .{ .{ .types = false }, "b:" },
        .{ .{ .parameters = false }, ": u32" },
        .{ .{ .hide_redundant_param_names = false }, ": u32 a: b:" },
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
    // 不以调用点的实例推导：显示抽象的类型，没有「inferred from」
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
    const items = try completion.complete(&r, added.file, added.cursor);
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    // 函数的别名 `isARM` 可作为方法调用；值常量 `count` 不列出
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
    const items = try completion.complete(&r, added.file, added.cursor);
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    // 第一个调用点（Rgb）下该分支不生效：取第二个调用点（Rgba）
    try testing.expectEqualStrings("r a", try std.mem.join(w.arena.allocator(), " ", labels.items));
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
        // 错误集的成员与匿名初始化的字段名：本身就是声明处
        .{ "Timeout", 0, "Timeout" },
        .{ "Closed", 0, "Closed" },
        .{ ".verbose", 1, "verbose" },
        .{ ".second", 1, "second" },
        // 有结果类型：跳到字段的声明
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
        \\};
        \\const c_ns = struct {
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
        // 别名 `system.SO` 与嵌套的 switch
        .{ "REUSEPORT_LB;", "REUSEPORT_LB = 0x10000" },
        // 当前配置下 EVFILT 为 void
        .{ "READ;", "READ = -1" },
        // 字段的类型、局部变量的 `init()`、调用结果
        .{ "handle;\n    var", "handle: u32" },
        .{ "handle;\n    _ = platform", "handle: u32" },
        .{ "handle;\n    _ = t", "handle: u32" },
        // 当前配置下存在的成员
        .{ "fd;\n}", "fd: u32" },
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
