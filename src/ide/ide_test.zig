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
const seed = database.ide_db.seed;
const search = @import("../ide_db/search.zig");

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

    // 裸 `u32` 是原始类型，不能解析到同名的转义参数
    const bare = std.mem.indexOf(u8, text, "local: u32").? + "local: ".len;
    try testing.expectEqual(null, try definition.definition(&r, file, @intCast(bare)));

    // 转义引用仍解析到参数
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

    const items = try completion.complete(&r, added.file, added.cursor);
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
    // 字段中的函数不绑定接收者：第一个实参对应 a
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
    // 经由别名调用（`const assert = std.debug.assert;`）时不跟随别名：没有签名帮助与参数名提示
    const text =
        \\fn add(a: u32, b: u32) u32 { return a + b; }
        \\const plus = add;
        \\const ns = struct { const sum = plus; };
        \\fn run(x: u32) void {
        \\    const local = add;
        \\    _ = plus(x, 1);
        \\    _ = ns.sum(x, 2);
        \\    _ = local(x, 3);
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
    const hints = try inlay_hints.inlayHints(&r, file, 0, @intCast(text.len), .{});
    var out: std.ArrayList(u8) = .empty;
    for (hints) |h| if (h.kind == .parameter) {
        try out.appendSlice(w.arena.allocator(), h.label);
        try out.append(w.arena.allocator(), ' ');
    };
    try testing.expectEqualStrings("a: b: a: b: a: b: ", out.items);
}

test "goto declaration of reified fields named by comptime parsed strings" {
    // 字段名从帮助文本中解析出来（zig-clap 的用法）：跳到帮助文本中的参数名
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
    // `@Struct` 的字段属性类型来自 std.builtin
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
        // 多行字符串的第二行
        .{ "beta, b.", "beta Second" },
        // 经由另一个常量的普通字符串
        .{ "count, c.", "count Number" },
        // 局部常量
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
    // `testing.expectEqual(.x, actual)` 中的字面量由被调函数经 `@TypeOf(expected, actual)` 转换：曾没有跳转目标
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
        // 构造的枚举：名字的字符串字面量
        .{ "slow, m", "slow\" }" },
        // peer type 为 optional
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
    // 合并推导中光标处的字面量类型为 `@Type(.enum_literal)`：曾被当作已有类型而不按迭代推导，没有跳转目标
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
    // 没有结果类型的 `if` / `switch`：分支按 peer type 转换，`.invalid` 是 Kind 的成员；曾没有跳转目标
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
    // `else => &.{}` 与切片做 peer type resolution 得到切片：曾求不出，补全为空
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
    // `@Enum` 构造的枚举（如 SyntaxKind）的成员曾没有跳转目标
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
        // 构造类型所在文件中的字符串字面量（经由值相同的局部别名 `more`）
        .{ "gamma or", "gamma\", \"delta" },
        // 构造所在成员中的局部常量；结果类型为 optional
        .{ "epsilon }", "epsilon\"}" },
        // `@typeInfo(Base)` 给出的成员名：Base 中的成员
        .{ "beta or", "beta };" },
        // 经类型访问
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
    // 不在函数中构造的类型曾按内容显示为匿名的 `enum { ... }`
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

test "goto declaration through comptime anytype parameters" {
    // `comptime H: anytype` 的实例记录实参值：类型实参的成员可以解析，原先只记录了实参的类型 `type`
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
        // 签名中的参数类型
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
    // `format(self, writer: anytype)` 只由 `{f}` 经 printValue 的 `value.format(w)` 调用：writer 为 `*std.Io.Writer`
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
    // `Thread.spawn(.{}, f, .{ a, b })`、`@call(.auto, f, .{ a })`：以元组元素调用
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

test "switch prongs on a comptime-known tagged union are inactive unless they match" {
    // 操作数是带标签的 union 时曾选不出执行的分支，其余分支都不判为非活动
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

/// 使用本机 zig 的真实标准库（PATH 中没有 zig 时跳过）：`@typeInfo` 需要 `std.builtin.Type`
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
    // 防止没有实例时把 `@hasDecl` / `@hasField` 求值为 false：有调用点的泛型代码中实际执行的分支显示为非活动
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
    // 防止为不属于任何模块的文件猜测根文件（如取文件自身）：它可能由另一个文件以相对路径 import，
    // 也可能由 `zig test` 编译（根文件是测试运行器）
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
        // 注释与字符串中不补全（曾列出作用域中的全部名字）
        .{ "fn f() void {\n    const p: S = .{ .x = 1 };\n    // p.<|>\n    _ = p;\n}", "" },
        .{ "fn f() void {\n    _ = \"p.<|>\";\n}", "" },
        .{ "fn f() void {\n    _ = \"p.<|>\n}", "" },
        .{ "/// a @<|>\nconst T = 1;", "" },
        // 错误名：期望类型的错误集成员，没有期望类型时为本文件中出现的错误名
        .{ "const E = error{ Worse, Bad };\nfn f() E!void {\n    return error.<|>;\n}", "Bad Worse" },
        .{ "const E = error{ Worse, Bad };\nfn g() void {\n    const e = error.<|>;\n    _ = e;\n}\nfn h() !void {\n    return error.Other;\n}", "Worse Bad Other" },
        // 未写完的 `error.` 接上了下一行的名字（`error._`），这个名字不列出
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

test "goto and hover on error values: the expected error set picks the declaration" {
    // `error.Foo` 曾既不能跳转也没有 hover
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
    // 期望的错误集 E 中的 Foo，而不是 Other 中的
    const foo = (try definition.definition(&r, file, at("Foo;") + 1)).?;
    try testing.expectEqual(file, foo.file);
    try testing.expectEqual(at("Foo,\n    Bar"), foo.start);
    // 没有期望类型：含这个名字的错误集
    const baz = (try definition.definition(&r, file, at("Baz;") + 1)).?;
    try testing.expectEqual(at("Baz }"), baz.start);
    // 合并的错误集：其中含这个名字的部分
    const bar = (try definition.definition(&r, file, at("Bar;") + 1)).?;
    try testing.expectEqual(at("Bar,\n};"), bar.start);
    // 其他文件中声明的错误集
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
        // `error.X` 按解码后的名字查找
        .{ "error.Escaped", "error.".len, "@\"\\x45scaped\"" },
        .{ "error.@\"\\x45scaped\"", "error.".len, "@\"\\x45scaped\"" },
        // `E.X` 的 token 原文带引号，区间覆盖 token 自身
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
    // hover 带上转义名字对应的文档
    const info = (try hover.hover(&r, file, at("error.Escaped") + @as(u32, "error.".len))).?;
    try testing.expect(std.mem.endsWith(u8, info.text, "escaped doc"));
}

test "goto on an error value without an expected error set stops at the first declaration" {
    // 没有期望的错误集时各声明同样符合，结果总是第一个；曾在找到后仍为 import 闭包中的全部文件建索引
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

test "completion in a switch prong on @typeInfo uses a call site where the prong is taken" {
    // 第一个调用点（结构体）下 `.pointer` 分支不执行，曾仍以它的实例补全出结构体的字段
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
    const items = try completion.complete(&r, added.file, added.cursor);
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    try testing.expectEqualStrings("len ptr", try std.mem.join(w.arena.allocator(), " ", labels.items));
}

/// 在 `text` 的 `<|>` 处补全，返回以空格连接的标签
fn completionLabels(text: []const u8) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r = resolver(&w, &ctx);
    const items = try completion.complete(&r, added.file, added.cursor);
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(testing.allocator, it.label);
    defer labels.deinit(testing.allocator);
    return testing.allocator.dupe(u8, try std.mem.join(w.arena.allocator(), " ", labels.items));
}

test "callsite seeding skips calls in branches the caller instance does not compile" {
    // 第一个实例（Input）下 `ensure` 的调用位于不执行的分支中：曾仍以它推导出 Input 的实例，补全出 Input 才有的字段
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
    // 唯一的调用位于调用者每个实例都不编译的分支中：曾因跳过这样的调用而没有实例，补全为空
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
    // 第一个调用点（Input）下 `Q.Memo` 不存在，`m` 的类型未知：曾补全为空
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
    // `if (!@hasDecl(Q, "fallback")) unreachable;` 在第一个调用点（A）下被选中，其后的代码不编译：曾仍以 A 补全
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
    // 运行时的条件之后的代码不是非活动代码
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
    // 左侧是运行时的值时右侧照常编译
    try testing.expectEqual(1, ranges.len);
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "x;").?)), ranges[0].start);
}

test "callsite seeding uses the caller instance with the matching comptime type argument" {
    // `A.step` 与 `B.step` 都经 `run` 中的 `Impl.step(ctx)` 调用；`run` 先以 B 调用，
    // A.step 内仍应使用 A 的实例
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
    // `caller(A, ..)` 不存在：编译器不会生成 `A.name` 的实例，不能借用 `caller(B, ..)` 的实例
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
    // 分派处（engine.zig 的 `Q.compute(ctx)`）所在的文件不 import 目标所在的文件：曾按导入链找不到调用点，`ctx` 的类型未知
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
    const items = try completion.complete(&r, added.file, added.cursor);
    var labels: std.ArrayList([]const u8) = .empty;
    for (items) |it| try labels.append(w.arena.allocator(), it.label);
    try testing.expectEqualStrings("n", try std.mem.join(w.arena.allocator(), " ", labels.items));
}

test "inside an inline for over a list of types, features use one iteration" {
    // 循环变量在推导中是抽象的（每次迭代的类型不同）：曾补全为空、hover 求不出类型
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
    // 调用位于遍历类型列表的 `inline for` 中，实参是抽象的循环变量：曾求不出 `get` 的实例
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
    // 曾只给类型的循环变量取值：下标 `i` 没有值，`tables[i]` 的元素求不出；其中嵌套的普通循环不影响选取
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
    // comptime 块中遍历类型列表的普通 `for`（不是 `inline for`）同样按迭代推导
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
    // 各项的类型不同（长度不同的数组、字符串），合并推导时循环变量的类型求不出：曾补全为空
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
    // 元组的值在运行时才知道，各项的类型 comptime 已知
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
    // 只有第 10 个实例有 `extra`，调用者又在泛型函数中：曾只尝试调用者的前 8 个实例，补全为空
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
    // 各项的载荷类型不同（`std.lang.Type.Struct` 与 `Union`），曾按 peer 求不出捕获的类型
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
    const items = try completion.complete(&r, added.file, added.cursor);
    var found = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "field_types")) found = true;
    }
    try testing.expect(found);
}

test "completion through single pointers to arrays, tuples and slices" {
    // 单指针解引用后曾直接查找命名空间：指向数组或元组时补全为空（如字符串常量的 `.len`）
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
        const items = try completion.complete(&r, added.file, added.cursor);
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
        // 函数返回类型按目标选择，字段的类型再按目标选择
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
    // `format` 提到 print，但调用的是 Writer.print：任何实例下都调用不到目标，不查找它自己的调用点
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
    // 只有目标自身的查找：`seedFor` 依次请求 Query、Instances 与 allInstances
    try testing.expectEqual(@as(u64, 1), w.db.executions(seed.Query));
    try testing.expectEqual(@as(u64, 2), w.db.executions(seed.Instances));
    // 改为调用目标后不再跳过：以 `format` 的调用点实例找到它对目标的调用
    const calling = try std.mem.replaceOwned(u8, w.arena.allocator(), text, "w.print(\"{}\");", "print(\"{}\", .{T});");
    _ = try w.add("/p/main.zig", calling);
    const moved = (try seedFor(&w, file, "print")).?;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, calling, "print(\"{}\", .{T})").?)), moved.offset);
}

test "seed callers are listed once per file and shared by every depth" {
    const text =
        \\pub fn print(comptime fmt: []const u8, args: anytype) void {
        \\    _ = fmt;
        \\    _ = args;
        \\}
        \\fn helper() void {}
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
    try expectCallers(&w, file, "print", &.{ "alias", "useAlias", "main" });
    // `seedFor` 依次请求各层的 Query 与 Instances：调用者列表只计算一次
    try testing.expectEqual(@as(u64, 1), w.db.executions(seed.Callers));

    // 新的调用者排在前面时被选中
    const calling = try std.mem.replaceOwned(u8, w.arena.allocator(), text, "fn helper() void {}", "fn helper() void {\n    print(\"{}\", .{@as(u32, 1)});\n}");
    _ = try w.add("/p/main.zig", calling);
    const moved = (try seedFor(&w, file, "print")).?;
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, calling, "print(\"{}\", .{@as(u32").?)), moved.offset);
    try expectCallers(&w, file, "print", &.{ "helper", "alias", "useAlias", "main" });
}

/// `file` 中名为 `name` 的泛型函数在 `file` 中的调用者（`seed.Callers`）依次为 `expected`
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
    const items = try completion.complete(&r, added.file, added.cursor);
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
        if (i != 0) for (try completion.complete(&r, added.file, added.cursor)) |item|
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
