//! hover：光标处名字的签名、类型与文档。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ast = @import("../syntax/ast.zig");
const definition = @import("definition.zig");
const context = @import("context.zig");
const render = @import("../sema/render.zig");
const queries = @import("../sema/queries.zig");
const TypedValue = @import("../sema/InternPool.zig").TypedValue;
const FileId = @import("../base/Vfs.zig").FileId;

pub const Info = struct {
    /// markdown
    text: []const u8,
    start: u32,
    end: u32,
};

pub fn hover(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Info {
    const tok = try definition.tokenAt(r, file, offset) orelse return null;
    if (tok.kind == .string_literal) return null;
    const a = try context.at(r, file, tok.offset, false) orelse return null;
    const b = a.body;

    var def: ?Def = null;
    var tv: TypedValue = .unknown;
    if (ast.memberName(a.node, try r.inEnum(file, a.item))) |name| if (name.offset == tok.offset) {
        def = .{ .item = .{ .file = file, .item = a.item } };
        tv = try r.ctx.get(queries.DeclType, a.owner);
    };
    if (def == null) for (b.bindings, 0..) |binding, i| {
        if (binding.range.start != tok.offset - a.node.offset) continue;
        const id: @import("../hir/Body.zig").BindingId = @fromBackingInt(@as(u32, @intCast(i)));
        def = .{ .local = .{ .file = file, .item = a.item, .binding = id } };
        tv = a.bindingType(id);
        break;
    };
    if (def == null) {
        const e = b.exprAt(tok.offset - a.node.offset) orelse return null;
        tv = a.exprType(e);
        switch (b.expr(e)) {
            .name_ref => |name| def = try r.resolveName(file, a.item, b, b.expr_scopes[@backingInt(e)], name),
            .field_access, .enum_literal => if (a.member(e)) |key| {
                def = try context.defOfKey(r, key);
            } else if (b.expr(e) == .field_access) {
                def = try definition.defAt(r, file, offset);
            },
            .builtin_call => {},
            else => return null,
        }
        // 声明以其声明类型显示（表达式可能经过了结果类型转换）
        if (def) |d| switch (d) {
            .item => |it| tv = try r.ctx.get(queries.DeclType, try r.ownerKey(it.file, it.item)),
            else => {},
        };
    }

    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    const code = if (def) |d| try context.signature(r, d, tv) else try render.typedValueAlloc(r, tv);
    if (tv.ty == .unknown and def == null) return null;
    w.print("```zig\n{s}\n```", .{code}) catch return error.OutOfMemory;
    if (def) |d| if (try context.doc(r, d)) |text| w.print("\n\n{s}", .{text}) catch return error.OutOfMemory;
    return .{ .text = out.written(), .start = tok.offset, .end = tok.offset + @as(u32, @intCast(tok.text.len)) };
}
