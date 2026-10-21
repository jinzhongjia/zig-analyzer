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
    return imports.complete(&r, file, offset, prefix, limit);
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
        "Widget: u32,\n",
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
