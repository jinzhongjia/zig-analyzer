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
const native = @import("../util/test_path.zig").native;
const InternPool = @import("../sema/InternPool.zig");

/// 内存中的项目：文件内容直接设置为 input，模块图手工构造
pub const World = struct {
    vfs: Vfs,
    ip: InternPool,
    env: database.Env,
    db: Db,
    arena: std.heap.ArenaAllocator,
    /// `setGraph` 时不属于任何模块的文件使用的 builtin
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

    /// 添加文件；返回去掉 `<|>` 后的光标位置（没有标记时为 0）
    pub fn add(w: *World, comptime path: []const u8, text: []const u8) !struct { file: FileId, cursor: u32 } {
        const file = try w.vfs.intern(native(path));
        const cursor = std.mem.indexOf(u8, text, "<|>");
        const clean = if (cursor) |c| try std.mem.concat(testing.allocator, u8, &.{ text[0..c], text[c + 3 ..] }) else try testing.allocator.dupe(u8, text);
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(FileText, file, clean, .low);
        return .{ .file = file, .cursor = @intCast(cursor orelse 0) };
    }

    pub fn setGraph(w: *World, std_root: ?FileId, modules: []const ModuleGraph.Module, files: []const ModuleGraph.FileEntry) !void {
        const g = try testing.allocator.create(ModuleGraph);
        const sorted = try w.arena.allocator().dupe(ModuleGraph.FileEntry, files);
        std.mem.sort(ModuleGraph.FileEntry, sorted, {}, struct {
            fn lt(_: void, a: ModuleGraph.FileEntry, b: ModuleGraph.FileEntry) bool {
                return @backingInt(a.file) < @backingInt(b.file);
            }
        }.lt);
        g.* = .{ .arena = .{}, .std_root = std_root, .modules = modules, .files = sorted, .default_builtin = w.default_builtin };
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(ModuleGraph.Input, {}, g, .low);
    }

    /// 设置与目标相关的值运算参数（同 Server 更新模块图时）
    pub fn setTarget(w: *World, t: InternPool.Target) !void {
        w.db.beginWrite();
        defer w.db.endWrite();
        try w.db.set(database.sema.TargetAbi, {}, t, .medium);
        w.ip.setTarget(t);
    }

    /// goto definition 的结果：「文件名:目标文本」
    fn goto(w: *World, file: FileId, offset: u32) ![]const u8 {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
        const t = try definition.definition(&r, file, offset) orelse return "null";
        return w.targetLabel(&ctx, t);
    }

    /// `definition.definitionTargets` / `declarationTargets` 的结果：各目标的「文件名:目标文本」，以空格连接
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

    /// 补全标签，按字母排序并以空格连接
    fn complete(w: *World, file: FileId, offset: u32) ![]const u8 {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
        const items = try completion.complete(&r, file, offset);
        const labels = try w.arena.allocator().alloc([]const u8, items.len);
        for (items, labels) |it, *l| l.* = it.label;
        std.mem.sort([]const u8, labels, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return std.mem.join(w.arena.allocator(), " ", labels);
    }
};

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
    // 光标在名字末尾
    try testing.expectEqualStrings("main.zig:total", try w.goto(f.file, f.cursor));
    // 声明自身
    try testing.expectEqualStrings("main.zig:run", try w.goto(f.file, at(text, "run", 0)));
    // 原生类型没有定义
    try testing.expectEqualStrings("null", try w.goto(f.file, at(text, "u32", 0)));

    try testing.expectEqualStrings("helper limit n run total", try w.complete(f.file, f.cursor));
}

test "imports: relative files, modules, std and root" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root = try w.add("/zig/std/std.zig", "pub const mem = @import(\"mem.zig\");\nconst hidden = 1;\n");
    const mem = try w.add("/zig/std/mem.zig", "pub const Allocator = @import(\"mem/Allocator.zig\");\npub fn eql() bool {}\nfn private() void {}\n");
    _ = try w.add("/zig/std/mem/Allocator.zig", "ptr: *anyopaque,\npub fn alloc() void {}\n");
    const lib = try w.add("/p/lib/lib.zig", "pub const Point = struct { x: i32, pub fn origin() Point {} };\n");
    _ = try w.add("/p/src/util.zig", "pub fn helper() void {}\n");
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
    const main = try w.add("/p/src/main.zig", src);
    try w.setGraph(std_root.file, &.{
        .{ .root = main.file, .imports = &.{.{ .name = "lib", .module = 1 }} },
        .{ .root = lib.file, .imports = &.{} },
    }, &.{
        .{ .file = main.file, .module = 0, .root_module = 0 },
        .{ .file = lib.file, .module = 1, .root_module = 0 },
        .{ .file = std_root.file, .module = ModuleGraph.std_module, .root_module = 0 },
        .{ .file = mem.file, .module = ModuleGraph.std_module, .root_module = 0 },
    });
    const text = try std.mem.replaceOwned(u8, w.arena.allocator(), src, "<|>", "");
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    try testing.expectEqualStrings("lib.zig:Point", try w.goto(main.file, at(text, "Point.origin")));
    try testing.expectEqualStrings("lib.zig:origin", try w.goto(main.file, at(text, "origin()")));
    try testing.expectEqualStrings("util.zig:helper", try w.goto(main.file, at(text, "helper()")));
    try testing.expectEqualStrings("mem.zig:Allocator", try w.goto(main.file, at(text, "Allocator;")));
    try testing.expectEqualStrings("Allocator.zig:alloc", try w.goto(main.file, at(text, "alloc;")));
    try testing.expectEqualStrings("main.zig:main", try w.goto(main.file, at(text, "main;")));
    // import 字符串跳转到文件开头
    try testing.expectEqualStrings("util.zig:", try w.goto(main.file, at(text, "util.zig") + 1));
    try testing.expectEqualStrings("std.zig:", try w.goto(main.file, at(text, "\"std\"")));
    // 其他文件只列出 pub 声明
    try testing.expectEqualStrings("Allocator eql", try w.complete(main.file, main.cursor));
}

test "imports of a file in several modules" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = try w.add("/p/a.zig", "pub fn fromA() u32 {}\n");
    const b = try w.add("/p/b.zig", "pub fn fromB() u32 {}\n");
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
    const main = try w.add("/p/src/main.zig", src);
    // exe 的模块（0）与 test 的模块（1）共用根文件：exe 中 dep → a；test 中 dep → b，另有 helper → b
    try w.setGraph(null, &.{
        .{ .root = main.file, .imports = &.{.{ .name = "dep", .module = 2 }} },
        .{ .root = main.file, .imports = &.{ .{ .name = "dep", .module = 3 }, .{ .name = "helper", .module = 3 } } },
        .{ .root = a.file, .imports = &.{} },
        .{ .root = b.file, .imports = &.{} },
    }, &.{
        .{ .file = main.file, .module = 0, .root_module = 0, .others = &.{1} },
        .{ .file = a.file, .module = 2, .root_module = 0 },
        .{ .file = b.file, .module = 3, .root_module = 1 },
    });
    const text = try std.mem.replaceOwned(u8, w.arena.allocator(), src, "<|>", "");
    const at = struct {
        fn of(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.of;
    // 只有 test 的模块 import 的名字
    try testing.expectEqualStrings("b.zig:", try w.goto(main.file, at(text, "\"helper\"")));
    try testing.expectEqualStrings("b.zig:fromB", try w.goto(main.file, at(text, "fromB")));
    // 两个模块都 import 的名字取优先的模块中的
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
    // exe 的模块（0）与 test 的模块（1）共用根文件：cfg 的目标不同，util 的相同
    try w.setGraph(null, &.{
        .{ .root = main.file, .imports = &.{ .{ .name = "cfg", .module = 2 }, .{ .name = "util", .module = 4 } } },
        .{ .root = main.file, .imports = &.{ .{ .name = "cfg", .module = 3 }, .{ .name = "util", .module = 4 } } },
        .{ .root = exe_cfg.file, .imports = &.{} },
        .{ .root = test_cfg.file, .imports = &.{} },
        .{ .root = util.file, .imports = &.{} },
    }, &.{
        .{ .file = main.file, .module = 0, .root_module = 0, .others = &.{1} },
        .{ .file = exe_cfg.file, .module = 2, .root_module = 0 },
        .{ .file = test_cfg.file, .module = 3, .root_module = 1 },
        .{ .file = util.file, .module = 4, .root_module = 0 },
    });
    const at = struct {
        fn of(needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, src, needle).?);
        }
    }.of;
    // `@import` 与它的字符串上：每个模块的目标，按模块的优先级
    for ([_]u32{ at("\"cfg\"") + 1, at("@import(\"cfg") + 1 }) |offset| {
        try testing.expectEqualStrings("exe_cfg.zig: test_cfg.zig:", try w.gotoAll(main.file, offset, definition.definitionTargets));
        try testing.expectEqualStrings("exe_cfg.zig: test_cfg.zig:", try w.gotoAll(main.file, offset, definition.declarationTargets));
        // 单个目标的入口取最优先的模块中的
        try testing.expectEqualStrings("exe_cfg.zig:", try w.goto(main.file, offset));
    }
    // 别名的使用处：definition 不越过 `@import`，与 declaration 一样停在声明处
    try testing.expectEqualStrings("main.zig:cfg", try w.gotoAll(main.file, at("cfg.mode"), definition.definitionTargets));
    try testing.expectEqualStrings("main.zig:cfg", try w.gotoAll(main.file, at("cfg.mode"), definition.declarationTargets));
    // 成员按最优先的模块解析
    try testing.expectEqualStrings("exe_cfg.zig:mode", try w.gotoAll(main.file, at("mode;"), definition.definitionTargets));
    // 各模块目标相同的名字与相对路径只有一个目标
    try testing.expectEqualStrings("util.zig:", try w.gotoAll(main.file, at("\"util\""), definition.definitionTargets));
    try testing.expectEqualStrings("local.zig:", try w.gotoAll(main.file, at("\"local.zig\""), definition.definitionTargets));
    try testing.expectEqualStrings("util.zig:helper", try w.gotoAll(main.file, at("helper()"), definition.definitionTargets));
    // 没有目标
    try testing.expectEqualStrings("", try w.gotoAll(main.file, at("void"), definition.definitionTargets));
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
    // 体内容器中引用外层函数的参数
    try testing.expectEqualStrings("main.zig:T", try w.goto(f.file, at(text, "T,")));
    try testing.expectEqualStrings("main.zig:len", try w.goto(f.file, at(text, "len; _")));
    try testing.expectEqualStrings("main.zig:green", try w.goto(f.file, at(text, "green; ")));
    // 可见名字：参数、容器成员、外层函数的参数与文件级声明
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
