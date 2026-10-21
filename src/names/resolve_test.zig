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
const test_path = @import("../util/test_path.zig");
const native = test_path.native;
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

    /// 添加的文件与去掉 `<|>` 后的光标位置（没有标记时为 0）
    pub const Added = struct { file: FileId, cursor: u32 };

    pub fn add(w: *World, comptime path: []const u8, text: []const u8) !Added {
        return w.addNative(native(path), text);
    }

    /// 同 `add`，`path` 已是本机路径
    fn addNative(w: *World, path: []const u8, text: []const u8) !Added {
        const file = try w.vfs.intern(path);
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

    /// `fixture` 中的文件与 `<|>` 的位置
    pub const Fixture = struct {
        /// fixture 中写的路径（posix 写法）与对应的文件
        paths: []const []const u8,
        files: []const FileId,
        /// `<|>` 所在的文件与去掉标记后的位置
        cursor: ?struct { file: FileId, offset: u32 } = null,

        pub fn file(f: Fixture, path: []const u8) FileId {
            for (f.paths, f.files) |p, id| if (std.mem.eql(u8, p, path)) return id;
            std.debug.panic("fixture has no file {s}", .{path});
        }
    };

    /// 多文件、多模块的测试项目（参照 rust-analyzer 的 fixture）。每个文件以一行 `//- <路径> <属性>...` 开始，路径用
    /// posix 写法。属性决定文件在模块图中的位置，没有属性的文件不在模块图中：
    /// - `std`：标准库中的文件，其中的 `std.zig` 是标准库的根；
    /// - `module:<名字>`：作为这个模块的根，紧随其后的 `deps:<名字>[=<模块>],...` 是这个模块的 import（import 的名字
    ///   与模块名相同时省略 `=<模块>`）；同一行可以有多个 `module:`，即同一个根文件属于多个模块；
    /// - `in:<模块>`：属于这个模块。
    /// 模块按声明顺序编号，文件属于多个模块时先写的优先。模块的 `@import("root")` 指向按声明顺序第一个能经由
    /// import 到达它的、没有被其他模块 import 的模块
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

        // 模块按声明顺序编号
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

        // 各模块的根模块：从没有被 import 的模块出发按声明顺序遍历，先到达的为准
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
                try entries.append(a, .{ .file = id, .module = ModuleGraph.std_module, .root_module = 0 });
                if (std.mem.endsWith(u8, b.path, "/std.zig")) std_root = id;
            } else if (in.items.len != 0) {
                try entries.append(a, .{ .file = id, .module = in.items[0], .root_module = root_of[in.items[0]], .others = in.items[1..] });
            }
        }
        try w.setGraph(std_root, modules, entries.items);
        return out;
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
    // 先写的模块优先，被 test 的模块 import 的 b 以它为根
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
        try testing.expectEqual(e.root, entry.root_module);
        try testing.expectEqualSlices(u32, e.others, entry.others);
    }
    // 没有属性的文件不在模块图中
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
    // exe 的模块与 test 的模块共用根文件：exe 中 dep → a；test 中 dep → b，另有 helper → b
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
