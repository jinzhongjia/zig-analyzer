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
const Body = @import("../hir/Body.zig");
const seed = @import("../ide_db/seed.zig");
const builtins = @import("builtins.zig");

pub const Info = struct {
    /// markdown
    text: []const u8,
    start: u32,
    end: u32,
};

pub fn hover(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Info {
    const tok = try definition.tokenAt(r, file, offset) orelse return null;
    if (tok.kind == .string_literal) return null;
    if (tok.kind == .builtin) {
        const entry = builtins.get(tok.text) orelse return null;
        var out: std.Io.Writer.Allocating = .init(r.arena);
        const w = &out.writer;
        if (entry.signature) |signature| w.print("```zig\n{s}\n```\n\n", .{signature}) catch return error.OutOfMemory;
        w.writeAll(entry.documentation) catch return error.OutOfMemory;
        if (try semanticHover(r, file, offset, tok)) |inferred| {
            w.print("\n\nInferred result:\n\n{s}", .{inferred.text}) catch return error.OutOfMemory;
        }
        return .{ .text = out.written(), .start = tok.offset, .end = tok.range().end };
    }
    return semanticHover(r, file, offset, tok);
}

fn semanticHover(r: *Resolver, file: FileId, offset: u32, tok: ast.SyntaxToken) resolve.Error!?Info {
    const a = try context.at(r, file, tok.offset, false) orelse return null;
    const b = a.body;

    var def: ?Def = null;
    var tv: TypedValue = .unknown;
    // tv 来自哪个绑定或表达式（以调用点的实例重新推导时取同一位置）
    var binding_id: ?Body.BindingId = null;
    var expr_id: ?Body.ExprId = null;
    if (ast.memberName(a.node, try r.inEnum(file, a.item))) |name| if (name.offset == tok.offset) {
        // decltest：名字指向它引用的声明，而不是 test 自身
        if (a.node.kind() == .test_decl and name.kind == .identifier) {
            def = try r.resolveContainerName(file, a.item, try ast.identNameAlloc(r.arena, name.text));
            if (def) |d| tv = try queries.defType(r, d, null, null);
        } else {
            def = .{ .item = .{ .file = file, .item = a.item } };
            tv = try r.ctx.get(queries.DeclType, .{ .owner = a.owner });
        }
    };
    if (def == null) for (b.bindings, 0..) |binding, i| {
        if (binding.range.start != tok.offset - a.node.offset) continue;
        const id: Body.BindingId = @fromBackingInt(@as(u32, @intCast(i)));
        def = .{ .local = .{ .file = file, .item = a.item, .binding = id } };
        tv = a.bindingType(id);
        binding_id = id;
        break;
    };
    if (def == null) {
        const e = b.exprAt(tok.offset - a.node.offset) orelse return null;
        tv = a.exprType(e);
        expr_id = e;
        switch (b.expr(e)) {
            .name_ref => |name| {
                if (!Body.nameRefIsBuiltin(b, e)) def = try r.resolveName(file, a.item, b, b.expr_scopes[@backingInt(e)], name);
            },
            .field_access, .enum_literal => if (a.member(e)) |key| {
                def = try context.defOfKey(r, key);
            } else if (b.expr(e) == .field_access) {
                def = try definition.defAt(r, file, offset);
            },
            .builtin_call => {},
            .error_value => |name| return errorValue(r, file, tok, e, name),
            else => return null,
        }
        // 直接引用的声明以其声明类型显示（表达式可能经过了结果类型转换）；
        // 成员访问保留表达式的类型（泛型实例中的成员类型由实例决定）
        if (b.expr(e) == .name_ref) if (def) |d| switch (d) {
            .item => |it| tv = try r.ctx.get(queries.DeclType, .{ .owner = try r.ownerKey(it.file, it.item) }),
            else => {},
        };
    }

    // 泛型函数体内没有具体实例：以调用点的实例推导
    var seeded_from: ?seed.Seed = null;
    if ((binding_id != null or expr_id != null) and seed.wanted(r.ctx.db.env.ip, tv)) {
        const subject: seed.Subject = if (binding_id) |id| .{ .binding = id } else .{ .expr = expr_id.? };
        const rel = tok.offset - a.node.offset;
        var refiner = try seed.Refiner.init(r, file, a.item, a.node.offset, b, a.res);
        if (try refiner.at(rel, subject)) |s| {
            const res = s.res;
            const better: TypedValue = if (binding_id) |id|
                (if (@backingInt(id) < res.bindings.len) res.bindings[@backingInt(id)] else .unknown)
            else if (@backingInt(expr_id.?) < res.exprs.len) res.exprs[@backingInt(expr_id.?)] else .unknown;
            if (!seed.wanted(r.ctx.db.env.ip, better)) {
                tv = better;
                seeded_from = s;
            }
        }
    }

    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    const code = if (def) |d| try context.signature(r, d, tv) else try render.exprAlloc(r, tv);
    if (tv.ty == .unknown and def == null) return null;
    w.print("```zig\n{s}\n```", .{code}) catch return error.OutOfMemory;
    if (seeded_from) |s| {
        const text = (try r.ctx.get(@import("../database.zig").syntax.SourceText, s.file)).text;
        const line = std.mem.count(u8, text[0..@min(s.offset, text.len)], "\n") + 1;
        const where = std.fs.path.basename(r.ctx.db.env.vfs.path(s.file));
        if (s.iteration) |n|
            w.print("\n\ninferred from iteration {d} of the loop at {s}:{d}", .{ n + 1, where, line }) catch return error.OutOfMemory
        else
            w.print("\n\ninferred from the call at {s}:{d}", .{ where, line }) catch return error.OutOfMemory;
    }
    if (def) |d| if (try context.doc(r, d)) |text| w.print("\n\n{s}", .{text}) catch return error.OutOfMemory;
    return .{ .text = out.written(), .start = tok.offset, .end = tok.offset + @as(u32, @intCast(tok.text.len)) };
}

/// `error.Foo`：错误名与期望的错误集；当前文件中有它的声明时附上文档
fn errorValue(r: *Resolver, file: FileId, tok: ast.SyntaxToken, e: Body.ExprId, name: []const u8) resolve.Error!?Info {
    if (name.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    if (try definition.expectedErrorSet(r, file, tok.offset, e)) |set| {
        w.print("```zig\nerror.{s}: {s}\n```", .{ name, try render.typeAlloc(r, set) }) catch return error.OutOfMemory;
    } else {
        w.print("```zig\nerror.{s}\n```", .{name}) catch return error.OutOfMemory;
    }
    if (try definition.errorValueDecl(r, file, tok.offset, false)) |d| if (d.doc) |doc| w.print("\n\n{s}", .{doc}) catch return error.OutOfMemory;
    return .{ .text = out.written(), .start = tok.offset, .end = tok.offset + @as(u32, @intCast(tok.text.len)) };
}
