const std = @import("std");
const testing = std.testing;
const imports = @import("imports.zig");
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;
const FileId = @import("../base/Vfs.zig").FileId;
const database = @import("../database.zig");

fn run(w: *World, file: FileId, offset: u32, prefix: []const u8, limit: usize) !imports.Result {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    return imports.complete(&r, file, offset, .unknown, prefix, limit);
}
fn find(result: imports.Result, label: []const u8) ?imports.Candidate {
    for (result.items) |item| if (std.mem.eql(u8, item.label, label)) return item;
    return null;
}
fn editContaining(result: imports.Result, needle: []const u8) ?imports.Candidate {
    for (result.items) |item| if (item.import_edit) |edit| {
        if (std.mem.indexOf(u8, edit.text, needle) != null) return item;
    };
    return null;
}

test "auto imports cover modules file names top declarations and nested types" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:wire=dep
        \\//! Application docs.
        \\fn main() void { _ = <|>missing; }
        \\//- /p/Server.zig in:app
        \\pub const Service = struct { pub const Index = u32; };
        \\//- /dep/root.zig module:dep
        \\pub const Header = struct {};
        \\//- /zig/std/std.zig std
        \\pub const ArrayList = struct {};
    );
    const at = f.cursor.?;
    const module = find(try run(&w, at.file, at.offset, "st", 128), "std").?;
    try testing.expectEqualStrings("const std = @import(\"std\");\n", module.import_edit.?.text);
    try testing.expectEqual(@as(u32, "//! Application docs.\n".len), module.import_edit.?.start);
    const file = find(try run(&w, at.file, at.offset, "Serv", 128), "Server").?;
    try testing.expectEqualStrings("const Server = @import(\"Server.zig\");\n", file.import_edit.?.text);
    const decl = find(try run(&w, at.file, at.offset, "Servi", 128), "Service").?;
    try testing.expectEqualStrings("const Service = @import(\"Server.zig\").Service;\n", decl.import_edit.?.text);
    const nested = find(try run(&w, at.file, at.offset, "Ind", 128), "Index").?;
    try testing.expectEqualStrings("const Index = @import(\"Server.zig\").Service.Index;\n", nested.import_edit.?.text);
    const named = find(try run(&w, at.file, at.offset, "Hea", 128), "Header").?;
    try testing.expectEqualStrings("const Header = @import(\"wire\").Header;\n", named.import_edit.?.text);
    const truncated = try run(&w, at.file, at.offset, "Serv", 1);
    try testing.expectEqual(@as(usize, 1), truncated.items.len);
    try testing.expect(truncated.is_incomplete);
    const zero = try run(&w, at.file, at.offset, "st", 0);
    try testing.expectEqual(@as(usize, 0), zero.items.len);
    try testing.expect(zero.is_incomplete);
    try testing.expectEqual(@as(usize, 0), (try run(&w, at.file, at.offset, "", 128)).items.len);
}

test "auto imports reuse deep aliases and never leak dependency internal paths" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:wire=dep
        \\const Ast = @import("std").zig.Ast;
        \\fn main() void { _ = <|>missing; }
        \\//- /dep/root.zig module:dep
        \\pub const Exported = @import("internal.zig").Hidden;
        \\//- /dep/internal.zig in:dep
        \\pub const Hidden = struct { pub const WireIndex = u32; };
        \\pub const Unexported = u8;
        \\//- /zig/std/std.zig std
        \\pub const zig = @import("zig.zig");
        \\//- /zig/std/zig.zig std
        \\pub const Ast = @import("Ast.zig");
        \\//- /zig/std/Ast.zig std
        \\pub const Node = struct { pub const Index = u32; };
    );
    const at = f.cursor.?;
    const aliases = try run(&w, at.file, at.offset, "Ind", 128);
    const index = find(aliases, "Ast.Node.Index").?;
    try testing.expect(index.import_edit == null);
    try testing.expect(find(aliases, "Index") == null);
    const wire = find(try run(&w, at.file, at.offset, "Wire", 128), "WireIndex").?;
    try testing.expectEqualStrings("const WireIndex = @import(\"wire\").Exported.WireIndex;\n", wire.import_edit.?.text);
    try testing.expectEqual(@as(usize, 0), (try run(&w, at.file, at.offset, "Unexport", 128)).items.len);
}

test "auto imports traverse the full public std export closure and terminate cycles" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const value = <|>missing;
        \\//- /zig/std/std.zig std
        \\pub const zig = @import("zig.zig");
        \\//- /zig/std/zig.zig std
        \\pub const Ast = @import("Ast.zig");
        \\pub const cycle = @import("std.zig");
        \\const Private = struct { pub const PrivateIndex = u32; };
        \\//- /zig/std/Ast.zig std
        \\pub const Node = struct { pub const Index = u32; };
    );
    const at = f.cursor.?;
    const index = find(try run(&w, at.file, at.offset, "Ind", 128), "Index").?;
    try testing.expectEqualStrings("const Index = @import(\"std\").zig.Ast.Node.Index;\n", index.import_edit.?.text);
    try testing.expectEqual(@as(usize, 0), (try run(&w, at.file, at.offset, "PrivateI", 128)).items.len);
}

test "auto imports skip module roots that are not zig source files" {
    // 模块的根可以是数据文件（如 `addAnonymousImport` 引入的 JSON），不能按 Zig 解析：大文件很慢
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:data=data
        \\fn main() void { _ = <|>missing; }
        \\//- /data/meta.json module:data
        \\pub const Leaked = u32;
    );
    const at = f.cursor.?;
    try testing.expectEqual(@as(usize, 0), (try run(&w, at.file, at.offset, "Leak", 128)).items.len);
}

test "auto imports respect primary module boundaries root subtrees and public chains" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/src/main.zig module:app
        \\fn main() void { _ = <|>missing; }
        \\//- /p/src/visible.zig in:app
        \\pub const PublicName = u32;
        \\const Private = struct { pub const PrivateIndex = u32; };
        \\pub const Public = struct { const SecretIndex = u32; };
        \\pub const Aggregate = .{ .x = struct { pub const BogusIndex = u32; } };
        \\fn Type() type { return struct { pub const FunctionIndex = u32; }; }
        \\//- /p/outside.zig in:app
        \\pub const OutsideName = u32;
        \\//- /dep/root.zig module:dep
        \\pub const ForeignName = u32;
    );
    const at = f.cursor.?;
    try testing.expect(find(try run(&w, at.file, at.offset, "PublicN", 128), "PublicName") != null);
    for ([_][]const u8{ "PrivateI", "SecretI", "BogusI", "FunctionI", "OutsideN", "ForeignN" }) |prefix|
        try testing.expectEqual(@as(usize, 0), (try run(&w, at.file, at.offset, prefix, 128)).items.len);
}

test "auto imports use same file private qualified paths and reject local alias conflicts" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const Private = struct { const Index = u32; };
        \\fn main() void { _ = <|>missing; }
        \\//- /p/other.zig in:app
        \\pub const Exported = u32;
    );
    const at = f.cursor.?;
    const nested = find(try run(&w, at.file, at.offset, "Ind", 128), "Private.Index").?;
    try testing.expect(nested.import_edit == null);
    const changed = try w.add("/p/main.zig",
        \\const Private = struct { const Index = u32; };
        \\fn main() void { const Exported = 1; const Private = 2; _ = Ex<|>ported; }
    );
    try testing.expectEqual(@as(usize, 0), (try run(&w, changed.file, changed.cursor, "Ex", 128)).items.len);
    try testing.expectEqual(@as(usize, 0), (try run(&w, changed.file, changed.cursor, "Ind", 128)).items.len);
}

test "auto import edit follows last import and source identifiers are escaped by segment" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\//! Docs.
        \\const Existing = @import("existing.zig"); // keep
        \\fn main() void { _ = <|>missing; }
    ;
    const f = try w.fixture(
        "//- /p/main.zig module:app\n" ++ text ++
            "\n//- /p/existing.zig in:app\n" ++
            "\n//- /p/other.zig in:app\n" ++
            "pub const @\"switch\" = struct { pub const @\"odd-name\" = u32; };\n",
    );
    const at = f.cursor.?;
    const keyword = find(try run(&w, at.file, at.offset, "swi", 128), "@\"switch\"").?;
    try testing.expectEqualStrings("const @\"switch\" = @import(\"other.zig\").@\"switch\";\n", keyword.import_edit.?.text);
    try testing.expectEqual(@as(u32, "//! Docs.\nconst Existing = @import(\"existing.zig\"); // keep\n".len), keyword.import_edit.?.start);
    const odd = find(try run(&w, at.file, at.offset, "odd", 128), "@\"odd-name\"").?;
    try testing.expectEqualStrings("const @\"odd-name\" = @import(\"other.zig\").@\"switch\".@\"odd-name\";\n", odd.import_edit.?.text);
}

test "auto import indexes invalidate when initializer changes without changing item tree" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const value = <|>missing;
        \\//- /p/types.zig in:app
        \\pub const Namespace = struct { pub const Index = u32; };
    );
    const at = f.cursor.?;
    try testing.expect(find(try run(&w, at.file, at.offset, "Ind", 128), "Index") != null);
    _ = try w.add("/p/types.zig", "pub const Namespace = .{ .x = struct { pub const Index = u32; } };\n");
    try testing.expectEqual(@as(usize, 0), (try run(&w, at.file, at.offset, "Ind", 128)).items.len);
    _ = try w.add("/p/types.zig", "pub const Namespace = struct { pub const Index = u32; };\n");
    try testing.expect(find(try run(&w, at.file, at.offset, "Ind", 128), "Index") != null);
}

test "auto import graph changes update named module availability" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const main = try w.add("/p/main.zig", "const value = <|>missing;\n");
    const dep = try w.add("/dep/root.zig", "pub const Available = u32;\n");
    const modules = [_]database.ModuleGraph.Module{
        .{ .root = main.file, .imports = &.{.{ .name = "dependency", .module = 1 }} },
        .{ .root = dep.file, .imports = &.{} },
    };
    const files = [_]database.ModuleGraph.FileEntry{
        .{ .file = main.file, .module = 0, .root_module = 0 },
        .{ .file = dep.file, .module = 1, .root_module = 0 },
    };
    try w.setGraph(null, &modules, &files);
    try testing.expect(editContaining(try run(&w, main.file, main.cursor, "Avail", 128), "@import(\"dependency\").Available") != null);
    const changed = [_]database.ModuleGraph.Module{
        .{ .root = main.file, .imports = &.{} },
        .{ .root = dep.file, .imports = &.{} },
    };
    try w.setGraph(null, &changed, &files);
    try testing.expectEqual(@as(usize, 0), (try run(&w, main.file, main.cursor, "Avail", 128)).items.len);
}

test "auto imports use safe parent relative paths and the primary module only" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const root = try w.add("/p/root.zig", "");
    const current = try w.add("/p/sub/main.zig", "const value = <|>missing;\n");
    const target = try w.add("/p/Server.zig", "pub const ServerType = struct {};\n");
    const other = try w.add("/other/root.zig", "");
    const foreign = try w.add("/other/Shared.zig", "pub const SharedType = u32;\n");
    const modules = [_]database.ModuleGraph.Module{
        .{ .root = root.file, .imports = &.{} },
        .{ .root = other.file, .imports = &.{} },
    };
    const files = [_]database.ModuleGraph.FileEntry{
        .{ .file = root.file, .module = 0, .root_module = 0 },
        .{ .file = current.file, .module = 0, .root_module = 0, .others = &.{1} },
        .{ .file = target.file, .module = 0, .root_module = 0 },
        .{ .file = other.file, .module = 1, .root_module = 1 },
        .{ .file = foreign.file, .module = 1, .root_module = 1 },
    };
    try w.setGraph(null, &modules, &files);
    const server = find(try run(&w, current.file, current.cursor, "Server", 128), "Server").?;
    try testing.expectEqualStrings("const Server = @import(\"../Server.zig\");\n", server.import_edit.?.text);
    try testing.expectEqual(@as(usize, 0), (try run(&w, current.file, current.cursor, "Shared", 128)).items.len);
}

test "auto imports preserve mutable globals through their namespace" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:lib=dep
        \\fn main() void { cou<|>nter = 7; }
        \\//- /dep/root.zig module:dep
        \\pub var counter: u32 = 1;
        \\pub const Inner = struct { pub var nested: u32 = 2; };
    );
    const at = f.cursor.?;
    const candidate = find(try run(&w, at.file, at.offset, "cou", 128), "lib.counter").?;
    try testing.expect(candidate.kind == .variable);
    try testing.expectEqualStrings("const lib = @import(\"lib\");\n", candidate.import_edit.?.text);
    try testing.expect(find(try run(&w, at.file, at.offset, "cou", 128), "counter") == null);
    const nested = find(try run(&w, at.file, at.offset, "nest", 128), "lib.Inner.nested").?;
    try testing.expectEqualStrings("const lib = @import(\"lib\");\n", nested.import_edit.?.text);
    const changed = try w.add("/p/main.zig", "const lib = @import(\"lib\");\nfn main() void { cou<|>nter = 7; }\n");
    const reused = find(try run(&w, changed.file, changed.cursor, "cou", 128), "lib.counter").?;
    try testing.expect(reused.import_edit == null);
}

test "auto imports avoid bindings in other owners and container fields" {
    const owners = [_][]const u8{
        "fn other(Widget: u32) u32 { return Widget; }\n",
        "fn other() void { const Widget = 1; _ = Widget; }\n",
        "fn other(xs: []const u32) void { for (xs) |Widget| { _ = Widget; } }\n",
        "const Inner = struct { const Widget = u32; };\n",
    };
    for (owners) |owner| {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const text = try std.fmt.allocPrint(w.arena.allocator(), "//- /p/main.zig module:app deps:lib=dep\n{s}fn main() void {{ _ = Widg<|>et; }}\n" ++
            "//- /dep/root.zig module:dep\npub const Widget = struct {{}};\n", .{owner});
        const f = try w.fixture(text);
        const at = f.cursor.?;
        const result = try run(&w, at.file, at.offset, "Widg", 128);
        try testing.expect(find(result, "Widget") == null);
        const candidate = find(result, "lib.Widget").?;
        try testing.expectEqualStrings("const lib = @import(\"lib\");\n", candidate.import_edit.?.text);
    }
}

test "auto imports remain available when both leaf and namespace bindings conflict" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:lib=dep
        \\fn other(Widget: u32, lib: u32) u32 { return Widget + lib; }
        \\fn main() void { _ = Widg<|>et; }
        \\//- /dep/root.zig module:dep
        \\pub const Widget = struct {};
        \\pub var counter: u32 = 1;
    );
    const at = f.cursor.?;
    const widget = find(try run(&w, at.file, at.offset, "Widg", 128), "@import(\"lib\").Widget").?;
    try testing.expect(widget.import_edit == null);
    const counter = find(try run(&w, at.file, at.offset, "cou", 128), "@import(\"lib\").counter").?;
    try testing.expect(counter.import_edit == null);
}

test "auto import binding conflicts update after a function body edit" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:lib=dep
        \\fn other() void {}
        \\fn main() void { _ = Widg<|>et; }
        \\//- /dep/root.zig module:dep
        \\pub const Widget = struct {};
    );
    const at = f.cursor.?;
    try testing.expect(find(try run(&w, at.file, at.offset, "Widg", 128), "Widget") != null);
    const changed = try w.add("/p/main.zig", "fn other() void { const Widget = 1; _ = Widget; }\nfn main() void { _ = Widg<|>et; }\n");
    const result = try run(&w, changed.file, changed.cursor, "Widg", 128);
    try testing.expect(find(result, "Widget") == null);
    try testing.expect(find(result, "lib.Widget") != null);
}

test "auto imports do not treat the completed module reference as a binding conflict" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\fn main() void { _ = std<|>; }
        \\//- /zig/std/std.zig std
    );
    const at = f.cursor.?;
    const candidate = find(try run(&w, at.file, at.offset, "std", 128), "std").?;
    try testing.expectEqualStrings("const std = @import(\"std\");\n", candidate.import_edit.?.text);
}

test "auto imports preserve extern const storage and readonly kind across flag edits" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:lib=dep
        \\fn main() void { _ = external<|>; }
        \\//- /p/Provider.zig in:app
        \\pub extern const project_counter: u32;
        \\//- /dep/root.zig module:dep
        \\pub extern const external_counter: u32;
        \\pub const API = @import("backing.zig");
        \\//- /dep/backing.zig in:dep
        \\pub extern const nested_counter: u32;
    );
    const at = f.cursor.?;
    const external = find(try run(&w, at.file, at.offset, "external", 128), "lib.external_counter").?;
    try testing.expect(external.kind == .constant);
    try testing.expectEqualStrings("const lib = @import(\"lib\");\n", external.import_edit.?.text);
    const nested = find(try run(&w, at.file, at.offset, "nested", 128), "lib.API.nested_counter").?;
    try testing.expectEqualStrings("const lib = @import(\"lib\");\n", nested.import_edit.?.text);
    const project = find(try run(&w, at.file, at.offset, "project", 128), "Provider.project_counter").?;
    try testing.expectEqualStrings("const Provider = @import(\"Provider.zig\");\n", project.import_edit.?.text);
    const changed = try w.add("/p/main.zig", "const Existing = @import(\"lib\");\nfn main() void { _ = external<|>; }\n");
    const reused = find(try run(&w, changed.file, changed.cursor, "external", 128), "Existing.external_counter").?;
    try testing.expect(reused.kind == .constant);
    try testing.expect(reused.import_edit == null);
    const unbound = try w.add("/p/main.zig", "fn main() void { _ = external<|>; }\n");
    _ = try w.add("/dep/root.zig", "pub const external_counter: u32 = 7;\n");
    const comptime_value = find(try run(&w, unbound.file, unbound.cursor, "external", 128), "external_counter").?;
    try testing.expectEqualStrings("const external_counter = @import(\"lib\").external_counter;\n", comptime_value.import_edit.?.text);
    _ = try w.add("/dep/root.zig", "pub extern const external_counter: u32;\n");
    try testing.expect(find(try run(&w, unbound.file, unbound.cursor, "external", 128), "lib.external_counter") != null);
    const conflict = try w.add("/p/main.zig", "fn other(lib: u32) u32 { return lib; }\nfn main() void { _ = external<|>; }\n");
    const direct = find(try run(&w, conflict.file, conflict.cursor, "external", 128), "@import(\"lib\").external_counter").?;
    try testing.expect(direct.kind == .constant);
    try testing.expect(direct.import_edit == null);
}

test "project imports follow public same file namespace aliases without private leakage" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\fn main() void { _ = Review<|>; }
        \\//- /p/Provider.zig in:app
        \\const Hidden = struct {
        \\    pub const ReviewWidget = struct {};
        \\    const Deep = struct { pub const ReviewNested = struct {}; };
        \\    pub const Branch = Deep;
        \\    const ReviewPrivate = u32;
        \\};
        \\pub const PublicAPI = Hidden;
        \\const PrivateAPI = struct { pub const ReviewSecret = u8; };
        \\//- /foreign/root.zig module:foreign
        \\pub const ReviewForeign = struct {};
    );
    const at = f.cursor.?;
    const result = try run(&w, at.file, at.offset, "Review", 128);
    try testing.expectEqualStrings("const ReviewWidget = @import(\"Provider.zig\").PublicAPI.ReviewWidget;\n", find(result, "ReviewWidget").?.import_edit.?.text);
    try testing.expectEqualStrings("const ReviewNested = @import(\"Provider.zig\").PublicAPI.Branch.ReviewNested;\n", find(result, "ReviewNested").?.import_edit.?.text);
    for ([_][]const u8{ "ReviewPrivate", "ReviewSecret", "ReviewForeign" }) |name| try testing.expect(find(result, name) == null);
    _ = try w.add("/p/Provider.zig",
        \\const Hidden = struct { pub const ReviewWidget = struct {}; };
        \\pub const PublicAPI = u32;
    );
    try testing.expect(find(try run(&w, at.file, at.offset, "Review", 128), "ReviewWidget") == null);
    _ = try w.add("/p/Provider.zig",
        \\const Hidden = struct { pub const ReviewWidget = struct {}; };
        \\pub const PublicAPI = Hidden;
    );
    try testing.expect(find(try run(&w, at.file, at.offset, "Review", 128), "ReviewWidget") != null);
    _ = try w.add("/p/Provider.zig",
        \\const Hidden = struct { pub const ReviewWidget = struct {}; };
        \\const PublicAPI = Hidden;
    );
    try testing.expect(find(try run(&w, at.file, at.offset, "Review", 128), "ReviewWidget") == null);
}

test "auto imports reuse direct type scalar function and value aliases by canonical target" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:lib=dep
        \\const Renamed = @import("lib").EdgeWidget;
        \\const Number = @import("lib").EdgeNumber;
        \\const callable = @import("lib").edgeFunction;
        \\const saved = @import("lib").edgeValue;
        \\const Root = @import("lib");
        \\fn main() void { _ = Edge<|>; }
        \\//- /dep/root.zig module:dep
        \\pub const EdgeWidget = @import("internal.zig").Widget;
        \\pub const EdgeNumber = u32;
        \\pub fn edgeFunction() void {}
        \\pub const edgeValue: u32 = 7;
        \\pub const @"u32" = struct {};
        \\//- /dep/internal.zig in:dep
        \\pub const Widget = struct { pub const EdgeChild = u8; };
    );
    const at = f.cursor.?;
    const cases = .{
        .{ "EdgeW", "Renamed", "EdgeWidget" },
        .{ "EdgeN", "Number", "EdgeNumber" },
        .{ "edgeF", "callable", "edgeFunction" },
        .{ "edgeV", "saved", "edgeValue" },
    };
    inline for (cases) |case| {
        const result = try run(&w, at.file, at.offset, case[0], 128);
        try testing.expectEqual(@as(usize, 1), result.items.len);
        const alias = find(result, case[1]).?;
        try testing.expectEqualStrings(case[2], alias.filter);
        try testing.expectEqualStrings("", alias.qualifier);
        try testing.expect(alias.import_edit == null);
    }
    const child = find(try run(&w, at.file, at.offset, "EdgeC", 128), "Renamed.EdgeChild").?;
    try testing.expect(child.import_edit == null);
    try testing.expect(find(try run(&w, at.file, at.offset, "u3", 128), "Number") == null);
}

test "direct alias reuse invalidates after renames target edits and shadowing" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:lib=dep
        \\const Renamed = @import("lib").EdgeWidget;
        \\fn main() void { _ = Edge<|>; }
        \\//- /dep/root.zig module:dep
        \\pub const EdgeWidget = struct {};
        \\pub const OtherWidget = struct {};
    );
    const at = f.cursor.?;
    try testing.expect(find(try run(&w, at.file, at.offset, "EdgeW", 128), "Renamed") != null);
    const retargeted = try w.add("/p/main.zig", "const Renamed = @import(\"lib\").OtherWidget;\nfn main() void { _ = Edge<|>; }\n");
    const changed = try run(&w, retargeted.file, retargeted.cursor, "EdgeW", 128);
    try testing.expect(find(changed, "Renamed") == null);
    try testing.expect(editContaining(changed, "@import(\"lib\")") != null);
    const renamed = try w.add("/p/main.zig", "const Different = @import(\"lib\").EdgeWidget;\nfn main() void { _ = Edge<|>; }\n");
    try testing.expect(find(try run(&w, renamed.file, renamed.cursor, "EdgeW", 128), "Different").?.import_edit == null);
    const shadowed = try w.add("/p/main.zig", "const Different = @import(\"lib\").EdgeWidget;\nfn main() void { const Different = 1; _ = Different; _ = Edge<|>; }\n");
    const result = try run(&w, shadowed.file, shadowed.cursor, "EdgeW", 128);
    try testing.expect(find(result, "Different") == null);
    try testing.expect(editContaining(result, "@import(\"lib\")") != null);
}

test "direct project aliases preserve public access paths and private alias targets" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const Renamed = @import("Provider.zig").PublicAPI.ReviewWidget;
        \\fn main() void { _ = Review<|>; }
        \\//- /p/Provider.zig in:app
        \\const Hidden = struct { pub const ReviewWidget = struct {}; };
        \\pub const PublicAPI = Hidden;
    );
    const at = f.cursor.?;
    const result = try run(&w, at.file, at.offset, "ReviewW", 128);
    try testing.expectEqual(@as(usize, 1), result.items.len);
    const alias = find(result, "Renamed").?;
    try testing.expectEqualStrings("ReviewWidget", alias.filter);
    try testing.expect(alias.import_edit == null);
}

test "canonical direct aliases update when a named module target changes" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const main = try w.add("/p/main.zig", "const Renamed = @import(\"lib\").EdgeWidget;\nfn main() void { _ = Edge<|>; }\n");
    const previous = try w.add("/old/root.zig", "pub const EdgeWidget = struct {};\n");
    const replacement = try w.add("/new/root.zig", "pub const EdgeWidget = struct {};\n");
    const modules = [_]database.ModuleGraph.Module{
        .{ .root = main.file, .imports = &.{ .{ .name = "lib", .module = 1 }, .{ .name = "previous", .module = 1 } } },
        .{ .root = previous.file, .imports = &.{} },
        .{ .root = replacement.file, .imports = &.{} },
    };
    const files = [_]database.ModuleGraph.FileEntry{
        .{ .file = main.file, .module = 0, .root_module = 0 },
        .{ .file = previous.file, .module = 1, .root_module = 0 },
        .{ .file = replacement.file, .module = 2, .root_module = 0 },
    };
    try w.setGraph(null, &modules, &files);
    const original = try run(&w, main.file, main.cursor, "EdgeW", 128);
    try testing.expectEqual(@as(usize, 1), original.items.len);
    try testing.expect(find(original, "Renamed").?.import_edit == null);
    const changed = [_]database.ModuleGraph.Module{
        .{ .root = main.file, .imports = &.{ .{ .name = "lib", .module = 2 }, .{ .name = "previous", .module = 1 } } },
        .{ .root = previous.file, .imports = &.{} },
        .{ .root = replacement.file, .imports = &.{} },
    };
    try w.setGraph(null, &changed, &files);
    const updated = try run(&w, main.file, main.cursor, "EdgeW", 128);
    try testing.expect(find(updated, "Renamed").?.import_edit == null);
    const other_target = editContaining(updated, "@import(\"previous\")").?;
    try testing.expectEqualStrings("EdgeWidget", other_target.filter);
}

test "project public path indexing stays within each file" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\fn main() void { _ = Review<|>; }
        \\//- /p/Provider.zig in:app
        \\pub const PublicAPI = @import("../outside.zig");
        \\//- /outside.zig
        \\pub const ReviewOutside = struct {};
    );
    const at = f.cursor.?;
    try testing.expectEqual(@as(usize, 0), (try run(&w, at.file, at.offset, "Review", 128)).items.len);
}

test "auto imports match prefixes regardless of case and rank the typed case first" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\fn main() void { _ = <|>missing; }
        \\//- /p/Lib.zig in:app
        \\pub const ArrayList = struct {};
        \\pub fn arrayCopy() void {}
        \\//- /zig/std/std.zig std
        \\pub const Io = struct {};
    );
    const at = f.cursor.?;
    const lower = try run(&w, at.file, at.offset, "arr", 128);
    try testing.expectEqual(@as(usize, 2), lower.items.len);
    try testing.expectEqualStrings("arrayCopy", lower.items[0].label);
    try testing.expectEqualStrings("ArrayList", lower.items[1].label);
    const title = try run(&w, at.file, at.offset, "Arr", 128);
    try testing.expectEqualStrings("ArrayList", title.items[0].label);
    try testing.expectEqualStrings("arrayCopy", title.items[1].label);
    // 截断时保留大小写一致的候选，无论先遇到哪一个
    for ([_][2][]const u8{ .{ "arr", "arrayCopy" }, .{ "Arr", "ArrayList" } }) |case| {
        const one = try run(&w, at.file, at.offset, case[0], 1);
        try testing.expectEqual(@as(usize, 1), one.items.len);
        try testing.expectEqualStrings(case[1], one.items[0].label);
        try testing.expect(one.is_incomplete);
    }
    try testing.expect(find(try run(&w, at.file, at.offset, "ST", 128), "std") != null);
    try testing.expect(find(try run(&w, at.file, at.offset, "lib", 128), "Lib") != null);
    try testing.expect(find(try run(&w, at.file, at.offset, "io", 128), "Io") != null);
}

test "auto imports keep declarations whose names differ only in case apart" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    // 跨文件的精确查找须与索引的顺序一致：按字节比较时找不到排在 `alpha`、`beta`、`gamma` 之后的 `Zone`
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:shapes=dep
        \\fn main() void { _ = <|>missing; }
        \\//- /dep/root.zig module:dep
        \\pub const Alias = @import("parts.zig").Zone;
        \\pub const Other = @import("parts.zig").zone;
        \\//- /dep/parts.zig in:dep
        \\pub const alpha = 1;
        \\pub const beta = 2;
        \\pub const gamma = 3;
        \\pub const Zone = struct { pub const Wide = u8; };
        \\pub const zone = struct { pub const Narrow = u8; };
    );
    const at = f.cursor.?;
    const wide = editContaining(try run(&w, at.file, at.offset, "Wide", 128), "Wide") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("const Wide = @import(\"shapes\").Alias.Wide;\n", wide.import_edit.?.text);
    const narrow = editContaining(try run(&w, at.file, at.offset, "Narrow", 128), "Narrow") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("const Narrow = @import(\"shapes\").Other.Narrow;\n", narrow.import_edit.?.text);
}

test "auto import resolves short alias chains independently of earlier long chains" {
    // 超过 max_depth 的长链不能把同一批声明里较短的链按起点深度截断：A30 距 Root 只有 19 跳，
    // 从 A0 求值到它时已接近深度上限，必须仍能在自己的起点求值出命名空间。
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(w.arena.allocator(), "const Root = struct { pub const Member = u32; };\n");
    for (0..50) |i| {
        if (i == 49) {
            try text.print(w.arena.allocator(), "const A{d} = Root;\n", .{i});
        } else {
            try text.print(w.arena.allocator(), "const A{d} = A{d};\n", .{ i, i + 1 });
        }
    }
    try text.appendSlice(w.arena.allocator(), "fn main() void { _ = Mem<|>ber; }\n");
    const added = try w.add("/p/main.zig", text.items);
    const result = try run(&w, added.file, added.cursor, "Mem", 128);
    try testing.expect(find(result, "A30.Member") != null);
}

test "auto import ignores member references and labels in other owners" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app deps:lib=dep
        \\const S = @import("types.zig").S;
        \\fn other(s: S) void { _ = s.Widget; }
        \\fn labels() void { Widget: { break :Widget; } }
        \\fn main() void { _ = Wid<|>get; }
        \\//- /p/types.zig in:app
        \\pub const S = struct { Widget: u32 };
        \\//- /dep/root.zig module:dep
        \\pub const Widget = struct {};
    );
    const at = f.cursor.?;
    const result = try run(&w, at.file, at.offset, "Wid", 128);
    const direct = find(result, "Widget") orelse return error.MissingDirectWidget;
    try testing.expect(direct.import_edit != null);
    try testing.expect(find(result, "lib.Widget") == null);
}

test "auto import inserts after a leading UTF-8 BOM" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", "\xEF\xBB\xBFconst value = st<|>;");
    const std_file = (try w.add("/lib/std/std.zig", "pub const standard = u32;\n")).file;
    try w.setGraph(std_file, &.{}, &.{});
    const standard = editContaining(try run(&w, added.file, added.cursor, "st", 128), "standard") orelse return error.MissingAutoImport;
    try testing.expectEqual(@as(u32, 3), standard.import_edit.?.start);
}

test "auto import keeps a BOM and file doc before the inserted import" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const source = "\xEF\xBB\xBF//! Docs.\nconst value = st<|>;";
    const added = try w.add("/p/main.zig", source);
    const std_file = (try w.add("/lib/std/std.zig", "pub const standard = u32;\n")).file;
    try w.setGraph(std_file, &.{}, &.{});
    const standard = editContaining(try run(&w, added.file, added.cursor, "st", 128), "standard") orelse return error.MissingAutoImport;
    try testing.expectEqual(@as(u32, "//! Docs.\n".len + 3), standard.import_edit.?.start);
}

test "auto import does not add an edit that overlaps an unfinished escaped name" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const B = @import("other.zig")
        \\@"Sta<|>
        \\//- /p/other.zig in:app
        \\pub const Other = u32;
        \\//- /p/types.zig in:app
        \\pub const standard = u32;
    );
    const at = f.cursor.?;
    const result = try run(&w, at.file, at.offset, "Sta", 128);
    try testing.expectEqual(@as(usize, 0), result.items.len);
}

test "escaped namespace alias roots produce one qualified candidate" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig",
        \\const @"odd.name" = struct { pub fn bar() void {} };
        \\fn main() void { _ = ba<|>r; }
    );
    const result = try run(&w, added.file, added.cursor, "ba", 128);
    var count: usize = 0;
    for (result.items) |item| {
        if (!std.mem.eql(u8, item.label, "@\"odd.name\".bar")) continue;
        count += 1;
        try testing.expectEqualStrings("@\"odd.name\"", item.qualifier);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "auto import offers the default builtin module and its exports" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", "fn main() void { _ = st<|>; }\n");
    const builtin = (try w.add("/zig/builtin.zig", "pub const Type = u32;\n")).file;
    w.default_builtin = builtin;
    try w.setGraph(null, &.{}, &.{});
    const module = find(try run(&w, added.file, added.cursor, "buil", 128), "builtin") orelse return error.MissingBuiltinModule;
    try testing.expectEqualStrings("const builtin = @import(\"builtin\");\n", module.import_edit.?.text);
    const exported = editContaining(try run(&w, added.file, added.cursor, "Ty", 128), "@import(\"builtin\").Type") orelse return error.MissingBuiltinExport;
    try testing.expectEqualStrings("const Type = @import(\"builtin\").Type;\n", exported.import_edit.?.text);
}

test "auto import uses the builtin of the file's module" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", "fn main() void { _ = st<|>; }\n");
    const builtin = (try w.add("/gen/builtin.zig", "pub const Type = u32;\n")).file;
    const modules = [_]database.ModuleGraph.Module{.{ .root = added.file, .builtin = builtin, .imports = &.{} }};
    const files = [_]database.ModuleGraph.FileEntry{.{ .file = added.file, .module = 0, .root_module = 0 }};
    try w.setGraph(null, &modules, &files);
    const module = find(try run(&w, added.file, added.cursor, "buil", 128), "builtin") orelse return error.MissingBuiltinModule;
    try testing.expect(module.import_edit != null);
    const exported = editContaining(try run(&w, added.file, added.cursor, "Ty", 128), "@import(\"builtin\").Type") orelse return error.MissingBuiltinExport;
    try testing.expect(exported.import_edit != null);
}

test "auto import reuses an existing relative path import alias" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(
        \\//- /p/main.zig module:app
        \\const S = @import("Server.zig");
        \\fn main() void { _ = Serv<|>ice; }
        \\//- /p/Server.zig in:app
        \\pub const Service = struct {};
    );
    const at = f.cursor.?;
    const candidate = find(try run(&w, at.file, at.offset, "Serv", 128), "S.Service") orelse return error.MissingPathAliasReuse;
    try testing.expect(candidate.import_edit == null);
}

test "exports cache evicts least recently used closures and restores them" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(w.arena.allocator(), "//- /p/root.zig module:root\n");
    for (0..1026) |i| try text.print(w.arena.allocator(), "//- /p/f{d}.zig in:root\npub const V = u32;\n", .{i});
    const f = try w.fixture(text.items);
    {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        for (f.files[1..]) |file| {
            _ = try ctx.get(imports.Exports, .{ .ns = .{ .file = file, .container = 0 } });
        }
    }
    try testing.expect(w.db.wantsSweep());
    try testing.expect(w.db.trySweep());
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    const first = try ctx.get(imports.Exports, .{ .ns = .{ .file = f.files[1], .container = 0 } });
    const last = try ctx.get(imports.Exports, .{ .ns = .{ .file = f.files[f.files.len - 1], .container = 0 } });
    try testing.expectEqual(@as(usize, 1), first.decls.len);
    try testing.expectEqual(@as(usize, 1), last.decls.len);
    try testing.expectEqualStrings("V", first.decls[0].name);
}
