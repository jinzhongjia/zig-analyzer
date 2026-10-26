const std = @import("std");
const testing = std.testing;
const Parse = @import("../syntax/Parse.zig");
const organize_imports = @import("organize_imports.zig");
const Options = organize_imports.Options;
const Edit = organize_imports.Edit;

fn apply(a: std.mem.Allocator, text: []const u8, edits: []const Edit) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    for (edits) |e| {
        try out.appendSlice(a, text[pos..e.start]);
        try out.appendSlice(a, e.text);
        pos = e.end;
    }
    try out.appendSlice(a, text[pos..]);
    return out.items;
}

/// 整理后的文本；整理的结果再整理一次没有编辑
fn organized(a: std.mem.Allocator, text: []const u8, opts: Options) ![]const u8 {
    const parse = try Parse.create(testing.allocator, text);
    defer parse.destroy();
    const result = try apply(a, text, (try organize_imports.organize(a, parse, opts)).edits);
    const again = try Parse.create(testing.allocator, result);
    defer again.destroy();
    try testing.expectEqual(0, (try organize_imports.organize(a, again, opts)).edits.len);
    return result;
}

test "organize imports: files that are already organized or have nothing to organize get no edits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "pub fn main() void {}\n",
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
        \\const clap = @import("clap");
        \\
        \\const Body = @import("Body.zig");
        \\const ast = @import("ast.zig");
        \\
    }) |text| {
        const parse = try Parse.create(testing.allocator, text);
        defer parse.destroy();
        try testing.expectEqual(0, (try organize_imports.organize(a, parse, .{})).edits.len);
    }
}

test "organize imports: groups std builtin root, modules and files, files nearest first by path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text =
        \\//! Docs.
        \\const z = @import("z.zig");
        \\const clap = @import("clap");
        \\const builtin = @import("builtin");
        \\const Sub = @import("sub/Sub.zig");
        \\const up = @import("../up.zig");
        \\const std = @import("std");
        \\const a2 = @import("a2.zig");
        \\
        \\const a10 = @import("a10.zig");
        \\const Big = @import("Big.zig");
        \\const build_options = @import("build_options");
        \\const root = @import("root");
        \\
        \\pub fn main() void {}
        \\
    ;
    // 数字按数值比较（a2 在 a10 之前），大写字母在小写字母之前
    try testing.expectEqualStrings(
        \\//! Docs.
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const root = @import("root");
        \\
        \\const build_options = @import("build_options");
        \\const clap = @import("clap");
        \\
        \\const Big = @import("Big.zig");
        \\const a2 = @import("a2.zig");
        \\const a10 = @import("a10.zig");
        \\const Sub = @import("sub/Sub.zig");
        \\const z = @import("z.zig");
        \\const up = @import("../up.zig");
        \\
        \\pub fn main() void {}
        \\
    , try organized(arena.allocator(), text, .{}));
    // 按声明名：std 组仍按固定顺序
    try testing.expectEqualStrings(
        \\//! Docs.
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const root = @import("root");
        \\
        \\const build_options = @import("build_options");
        \\const clap = @import("clap");
        \\
        \\const Big = @import("Big.zig");
        \\const Sub = @import("sub/Sub.zig");
        \\const a2 = @import("a2.zig");
        \\const a10 = @import("a10.zig");
        \\const up = @import("../up.zig");
        \\const z = @import("z.zig");
        \\
        \\pub fn main() void {}
        \\
    , try organized(arena.allocator(), text, .{ .sort = .name }));
}

test "organize imports: derived declarations follow their import or form the last group" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text =
        \\const mem = std.mem;
        \\const std = @import("std");
        \\const Allocator = mem.Allocator;
        \\const assert = std.debug.assert;
        \\const Thing = @import("lib.zig").Thing;
        \\const lib = @import("lib.zig");
        \\const Part = lib.Part;
        \\const Orphan = other.Orphan;
        \\const max = 3;
        \\const other = @import("other.zig");
        \\
    ;
    // 派生声明按展开后的路径排在它依赖的声明之后（多层的依次跟随）；依赖的声明在别的块中时在最后一组
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\const assert = std.debug.assert;
        \\const mem = std.mem;
        \\const Allocator = mem.Allocator;
        \\
        \\const lib = @import("lib.zig");
        \\const Part = lib.Part;
        \\const Thing = @import("lib.zig").Thing;
        \\
        \\const Orphan = other.Orphan;
        \\const max = 3;
        \\const other = @import("other.zig");
        \\
    , try organized(arena.allocator(), text, .{}));
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\const lib = @import("lib.zig");
        \\const Thing = @import("lib.zig").Thing;
        \\
        \\const Part = lib.Part;
        \\const Orphan = other.Orphan;
        \\const assert = std.debug.assert;
        \\const mem = std.mem;
        \\const Allocator = mem.Allocator;
        \\const max = 3;
        \\const other = @import("other.zig");
        \\
    , try organized(arena.allocator(), text, .{ .derived = .separate }));
}

test "organize imports: comments move with their declarations, other code splits blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text =
        \\//! Module docs.
        \\
        \\// Section comment, separated by a blank line: stays.
        \\
        \\const zeta = @import("zeta.zig"); // trailing
        \\/// Documented import.
        \\pub const Alpha = @import("Alpha.zig");
        \\// attached to beta
        \\const beta = @import("beta.zig");
        \\
        \\// floating comment ends the block
        \\
        \\const b2 = @import("b2.zig");
        \\const a1 = @import("a1.zig");
        \\fn f() void {}
        \\const y = @import("y.zig");
        \\const x = @import("x.zig");
    ;
    try testing.expectEqualStrings(
        \\//! Module docs.
        \\
        \\// Section comment, separated by a blank line: stays.
        \\
        \\/// Documented import.
        \\pub const Alpha = @import("Alpha.zig");
        \\// attached to beta
        \\const beta = @import("beta.zig");
        \\const zeta = @import("zeta.zig"); // trailing
        \\
        \\// floating comment ends the block
        \\
        \\const a1 = @import("a1.zig");
        \\const b2 = @import("b2.zig");
        \\fn f() void {}
        \\const x = @import("x.zig");
        \\const y = @import("y.zig");
    , try organized(arena.allocator(), text, .{}));
}

test "organize imports: CRLF files keep CRLF" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "const std = @import(\"std\");\r\n\r\nconst a = @import(\"a.zig\");\r\nconst b = @import(\"b.zig\");\r\n",
        try organized(arena.allocator(), "const b = @import(\"b.zig\");\r\nconst std = @import(\"std\");\r\nconst a = @import(\"a.zig\");\r\n", .{}),
    );
}

test "organize imports: declarations sharing a line and files with syntax errors are left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "const b = @import(\"b.zig\"); const a = @import(\"a.zig\");\n",
        "const b = @import(\"b.zig\");\nconst a = @import(\"a.zig\");\nfn broken( {}\n",
    }) |text| {
        const parse = try Parse.create(testing.allocator, text);
        defer parse.destroy();
        try testing.expectEqual(0, (try organize_imports.organize(a, parse, .{})).edits.len);
    }
}

test "version sort orders numbers by value, capitals first and underscores before other characters" {
    // Rust Style Guide 的 Sorting 一节中的例子（节选）
    const sorted = [_][]const u8{ "_ZYXW", "_abcd", "A2", "ABCD", "Z_YXW", "ZY_XW", "ZYXW", "ZYXW_", "a1", "abcd", "u_zzz", "u8", "u16", "u32", "u128", "ua", "usize", "uz", "v000", "v00", "v0", "v0s", "v00t", "v0u", "v001", "v01", "v1", "v009", "v09", "v9", "v010", "v10", "x64", "x86", "x86_32", "x86_64", "x86_128", "x87", "zyxw" };
    for (sorted[0 .. sorted.len - 1], sorted[1..]) |x, y| {
        testing.expectEqual(std.math.Order.lt, organize_imports.versionOrder(x, y)) catch |err| {
            std.debug.print("{s} < {s}\n", .{ x, y });
            return err;
        };
    }
}

fn inserted(a: std.mem.Allocator, text: []const u8, name: []const u8, spec: []const u8, decl: []const u8) ![]const u8 {
    const parse = try Parse.create(testing.allocator, text);
    defer parse.destroy();
    const ins = try organize_imports.Inserter.init(a, parse, .{});
    return apply(a, text, &.{try ins.edit(a, name, spec, "", decl)});
}

test "auto import inserts into the organized block at its sorted place, otherwise after the last import" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\const std = @import("std");
        \\
        \\const lib = @import("lib.zig");
        \\const zed = @import("zed.zig");
        \\
        \\fn main() void {}
        \\
    ;
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\const lib = @import("lib.zig");
        \\const mid = @import("mid.zig");
        \\const zed = @import("zed.zig");
        \\
        \\fn main() void {}
        \\
    , try inserted(a, text, "mid", "mid.zig", "const mid = @import(\"mid.zig\");"));
    // 新的组前后空一行
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\const clap = @import("clap");
        \\
        \\const lib = @import("lib.zig");
        \\const zed = @import("zed.zig");
        \\
        \\fn main() void {}
        \\
    , try inserted(a, text, "clap", "clap", "const clap = @import(\"clap\");"));
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\const lib = @import("lib.zig");
        \\const zed = @import("zed.zig");
        \\const zz = @import("zz.zig");
        \\
        \\fn main() void {}
        \\
    , try inserted(a, text, "zz", "zz.zig", "const zz = @import(\"zz.zig\");"));
    // 块没有整理好：不顺带重排，插在最后一条 import 之后
    try testing.expectEqualStrings(
        \\const b = @import("b.zig");
        \\const a = @import("a.zig"); // keep
        \\const c = @import("c.zig");
        \\fn main() void {}
    , try inserted(a, "const b = @import(\"b.zig\");\nconst a = @import(\"a.zig\"); // keep\nfn main() void {}", "c", "c.zig", "const c = @import(\"c.zig\");"));
    // 没有 import：文件头的 `//!` 文档之后
    try testing.expectEqualStrings(
        "//! Docs.\nconst c = @import(\"c.zig\");\nfn main() void {}",
        try inserted(a, "//! Docs.\nfn main() void {}", "c", "c.zig", "const c = @import(\"c.zig\");"),
    );
}
