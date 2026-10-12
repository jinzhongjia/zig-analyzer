//! `live` 诊断来源：官方解析器 + AstGen（等价于 `zig ast-check`），保证与编译器一致。
//!
//! 自研 CST 的错误不参与诊断（见设计 §11）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const ErrorBundle = std.zig.ErrorBundle;

const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const inputs = @import("../base/inputs.zig");

pub const Diagnostic = struct {
    /// 字节偏移区间（ErrorBundle 的 span_start / span_end）
    start: u32,
    end: u32,
    message: []const u8,
    notes: []const Note,
};

pub const Note = struct {
    start: u32,
    end: u32,
    message: []const u8,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator.State,
    items: []const Diagnostic,

    pub fn destroy(r: *Result, gpa: Allocator) void {
        var arena = r.arena.promote(gpa);
        arena.deinit();
    }
};

pub const Mode = enum { zig, zon };

/// 对文本运行解析与 AstGen（或 ZonGen），返回全部错误。
pub fn check(gpa: Allocator, text: []const u8, mode: Mode) Allocator.Error!*Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(source);
    var tree = try Ast.parse(gpa, source, .{ .mode = switch (mode) {
        .zig => .zig,
        .zon => .zon,
    } });
    defer tree.deinit(gpa);

    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    switch (mode) {
        .zig => {
            var zir = try std.zig.AstGen.generate(gpa, tree);
            defer zir.deinit(gpa);
            if (zir.hasCompileErrors()) try wip.addZirErrorMessages(zir, tree, source, "");
        },
        .zon => {
            const zoir = try std.zig.ZonGen.generate(gpa, tree, .{});
            defer zoir.deinit(gpa);
            if (zoir.hasCompileErrors()) try wip.addZoirErrorMessages(zoir, tree, source, "");
        },
    }
    var bundle = try wip.toOwnedBundle("");
    defer bundle.deinit(gpa);

    var items: std.ArrayList(Diagnostic) = .empty;
    if (bundle.errorMessageCount() != 0) {
        for (bundle.getMessages()) |msg_index| {
            const msg = bundle.getErrorMessage(msg_index);
            const span = spanOf(bundle, msg.src_loc);
            const notes = try arena.alloc(Note, msg.notes_len);
            for (notes, bundle.getNotes(msg_index)) |*note, note_index| {
                const n = bundle.getErrorMessage(note_index);
                const note_span = spanOf(bundle, n.src_loc);
                note.* = .{ .start = note_span[0], .end = note_span[1], .message = try arena.dupe(u8, bundle.nullTerminatedString(n.msg)) };
            }
            try items.append(arena, .{
                .start = span[0],
                .end = span[1],
                .message = try arena.dupe(u8, bundle.nullTerminatedString(msg.msg)),
                .notes = notes,
            });
        }
    }

    const result = try arena.create(Result);
    result.* = .{ .arena = undefined, .items = items.items };
    result.arena = arena_state.state;
    return result;
}

fn spanOf(bundle: ErrorBundle, loc: ErrorBundle.SourceLocationIndex) [2]u32 {
    if (loc == .none) return .{ 0, 0 };
    const sl = bundle.getSourceLocation(loc);
    return .{ sl.span_start, sl.span_end };
}

/// 文件的 live 诊断。`.zon` 文件按 ZON 处理。
pub const AstCheck = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *Result;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const text = try ctx.get(inputs.FileText, file) orelse "";
        const vfs: *Vfs = ctx.db.env;
        const mode: Mode = if (std.mem.endsWith(u8, vfs.path(file), ".zon")) .zon else .zig;
        return check(ctx.db.gpa, text, mode);
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b;
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        v.*.destroy(gpa);
    }
};

const testing = std.testing;

fn expectMessages(text: []const u8, mode: Mode, expected: []const []const u8) !void {
    const r = try check(testing.allocator, text, mode);
    defer r.destroy(testing.allocator);
    try testing.expectEqual(expected.len, r.items.len);
    for (expected, r.items) |e, d| try testing.expectEqualStrings(e, d.message);
}

// 预期值取自 `zig ast-check` 的实际输出
test "与 zig ast-check 一致的错误" {
    try expectMessages("fn f() void { var x = 1; }", .zig, &.{"unused local variable"});
    try expectMessages("const a = ;", .zig, &.{"expected expression, found ';'"});
    try expectMessages("const a = 1;\nconst a = 2;", .zig, &.{"duplicate struct member name 'a'"});
    try expectMessages("pub fn main() void {}", .zig, &.{});
}

test "ZON" {
    try expectMessages(".{ .a = 1 }", .zon, &.{});
    try expectMessages(".{ .a = 1, .a = 2 }", .zon, &.{"duplicate struct field name"});
}

test "错误位置与附注" {
    const text = "const a = 1;\nconst a = 2;";
    const r = try check(testing.allocator, text, .zig);
    defer r.destroy(testing.allocator);
    const d = r.items[0];
    try testing.expectEqualStrings("a", text[d.start..d.end]);
    try testing.expectEqual(2, d.notes.len);
    try testing.expectEqualStrings("duplicate name here", d.notes[0].message);
    try testing.expectEqualStrings("struct declared here", d.notes[1].message);
}
