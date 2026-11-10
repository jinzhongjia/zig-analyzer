//! hover: signature, type, and documentation of the name at the cursor; the official documentation
//! of field names in `build.zig.zon`.

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
const infer = @import("../sema/infer.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const Body = @import("../hir/Body.zig");
const seed = @import("../ide_db/seed.zig");
const builtins = @import("builtins.zig");
const manifest = @import("manifest.zig");
const project_config = @import("project_config.zig");

pub const Info = struct {
    /// markdown
    text: []const u8,
    start: u32,
    end: u32,
};

/// `roots`: the workspace folders, the paths of embedded files are shown relative to them (see
/// `Vfs.shownPath`)
pub fn hover(r: *Resolver, file: FileId, offset: u32, roots: []const []const u8) resolve.Error!?Info {
    const tok = try definition.tokenAt(r, file, offset) orelse return null;
    if (tok.kind == .string_literal) return null;
    if (tok.kind == .builtin) {
        const entry = builtins.get(tok.text) orelse return null;
        var out: std.Io.Writer.Allocating = .init(r.arena);
        const w = &out.writer;
        if (entry.signature) |signature| w.print("```zig\n{s}\n```\n\n", .{signature}) catch return error.OutOfMemory;
        const doc = try builtins.documentation(r.arena, entry, try r.ctx.get(@import("../database.zig").syntax.SyntaxDialect, {}));
        w.writeAll(doc) catch return error.OutOfMemory;
        if (try semanticHover(r, file, offset, tok, roots)) |inferred| {
            w.print("\n\nInferred result:\n\n{s}", .{inferred.text}) catch return error.OutOfMemory;
        }
        return .{ .text = out.written(), .start = tok.offset, .end = tok.range().end };
    }
    if (try manifest.fieldDoc(r, file, tok)) |doc| return .{ .text = doc, .start = tok.offset, .end = tok.range().end };
    if (try project_config.fieldDoc(r, file, tok)) |doc| return .{ .text = doc, .start = tok.offset, .end = tok.range().end };
    return semanticHover(r, file, offset, tok, roots);
}

fn semanticHover(r: *Resolver, file: FileId, offset: u32, tok: ast.SyntaxToken, roots: []const []const u8) resolve.Error!?Info {
    const a = try context.at(r, file, tok.offset, false) orelse return null;
    const b = a.body;

    var def: ?Def = null;
    var tv: TypedValue = .unknown;
    // The binding or expression tv comes from (the same position is used when re-inferring with a
    // call-site instance)
    var binding_id: ?Body.BindingId = null;
    var expr_id: ?Body.ExprId = null;
    if (ast.memberName(a.node, try r.inEnum(file, a.item))) |name| if (name.offset == tok.offset) {
        // decltest: the name refers to the declaration it references, not to the test itself
        if (a.node.kind() == .test_decl and name.kind == .identifier) {
            def = try r.resolveContainerName(file, a.item, try ast.identNameAlloc(r.arena, name.text));
            if (def) |d| tv = try queries.defType(r, d, null, null);
        } else {
            def = .{ .item = .{ .file = file, .item = a.item } };
            tv = try r.ctx.get(queries.DeclType, .{ .owner = a.owner });
        }
    };
    if (def == null) if (b.bindingAt(tok.offset - a.node.offset)) |id| {
        def = .{ .local = .{ .file = file, .item = a.item, .binding = id } };
        tv = a.bindingType(id);
        binding_id = id;
    };
    if (def == null) {
        const e = b.exprAt(tok.offset - a.node.offset) orelse return null;
        // The reference's own value: a result type coercion (`take(a)` with a `?u8` parameter)
        // does not change what the name or member is
        tv = a.uncoercedType(e);
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
            .init => return initFieldHover(r, file, tok, e),
            .error_value => |name| return errorValue(r, file, tok, e, name),
            else => return null,
        }
    }

    // A generic function body has no concrete instance: infer with a call-site instance
    const ip = r.ctx.db.env.ip;
    // An enum literal whose expected type contains parameters (`return .empty` in a function
    // returning `T`) names a declaration or tag only under an instance
    const instance_literal = def == null and expr_id != null and b.expr(expr_id.?) == .enum_literal and
        if (a.literalExpected(expr_id.?)) |t| seed.wanted(ip, .{ .ty = t }) else false;
    var seeded_from: ?seed.Seed = null;
    if ((binding_id != null or expr_id != null) and (instance_literal or seed.wanted(ip, tv))) {
        const subject: seed.Subject = if (binding_id) |id| .{ .binding = id } else .{ .expr = expr_id.? };
        const rel = tok.offset - a.node.offset;
        var refiner = try seed.Refiner.init(r, file, a.item, a.node.offset, b, a.res);
        if (try refiner.at(rel, subject)) |s| {
            const res = s.res;
            const better: TypedValue = if (binding_id) |id|
                (if (@backingInt(id) < res.bindings.len) res.bindings[@backingInt(id)] else .unknown)
            else
                res.uncoercedValue(expr_id.?);
            if (!seed.wanted(ip, better)) {
                tv = better;
                seeded_from = s;
                if (instance_literal) {
                    const i = @backingInt(expr_id.?);
                    if (i < res.members.len) if (res.members[i]) |key| {
                        def = try context.defOfKey(r, key);
                    };
                }
            }
        }
    }

    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    // A value that is directly the result of `@embedFile`: the call instead of the content
    const embed = if (def) |d| try context.embedOf(r, d, tv) else if (tv.val != null) try context.embedCall(r, a, expr_id.?) else null;
    const code = if (def) |d|
        try context.signature(r, d, tv, .multi_line)
    else if (embed) |e|
        try render.embedAlloc(r, tv.ty, e.path)
    else
        try render.exprAlloc(r, tv);
    if (tv.ty == .unknown and def == null) return null;
    w.print("```zig\n{s}\n```", .{code}) catch return error.OutOfMemory;
    if (embed) |e| writeEmbedded(w, r.ctx.db.env.vfs.shownPath(roots, r.ctx.db.env.vfs.path(e.file)), e.text) catch return error.OutOfMemory;
    if (seeded_from) |s| {
        w.writeAll("\n\ninferred from ") catch return error.OutOfMemory;
        try writeSource(w, r, s);
    }
    if (def) |d| if (try context.docOf(r, d, tv)) |text| w.print("\n\n{s}", .{text}) catch return error.OutOfMemory;
    return .{ .text = out.written(), .start = tok.offset, .end = tok.offset + @as(u32, @intCast(tok.text.len)) };
}

/// Where the instance `s` comes from: `the call at file.zig:12`, or the iteration of each loop
/// containing the position, outermost first
fn writeSource(w: *std.Io.Writer, r: *Resolver, s: seed.Seed) resolve.Error!void {
    const text = (try r.ctx.get(@import("../database.zig").syntax.SourceText, s.file)).text;
    const line = std.mem.count(u8, text[0..@min(s.offset, text.len)], "\n") + 1;
    const where = std.fs.path.basename(r.ctx.db.env.vfs.path(s.file));
    const n = s.iteration orelse {
        w.print("the call at {s}:{d}", .{ where, line }) catch return error.OutOfMemory;
        return;
    };
    for (s.enclosing, 0..) |outer, i| {
        const outer_line = std.mem.count(u8, text[0..@min(outer.offset, text.len)], "\n") + 1;
        const sep = if (i + 1 < s.enclosing.len) ", " else " and ";
        w.print("iteration {d} of the loop at {s}:{d}{s}", .{ outer.iteration + 1, where, outer_line, sep }) catch return error.OutOfMemory;
    }
    w.print("iteration {d} of the loop at {s}:{d}", .{ n + 1, where, line }) catch return error.OutOfMemory;
}
/// The file a value comes from with `@embedFile` and its size; its content when it is text of at
/// most `render.max_value_length` characters
fn writeEmbedded(w: *std.Io.Writer, path: []const u8, content: []const u8) std.Io.Writer.Error!void {
    try w.print("\n\nEmbedded file `{s}`: {d} bytes", .{ path, content.len });
    if (!isShortText(content)) return;
    // The fence is longer than any run of backticks in the content
    var fence: usize = 3;
    var run: usize = 0;
    for (content) |c| {
        run = if (c == '`') run + 1 else 0;
        fence = @max(fence, run + 1);
    }
    try w.writeAll("\n\n");
    try w.splatByteAll('`', fence);
    try w.writeAll("text\n");
    try w.writeAll(content);
    if (content.len > 0 and content[content.len - 1] != '\n') try w.writeByte('\n');
    try w.splatByteAll('`', fence);
}

/// Valid UTF-8 of at most `render.max_value_length` code points, without control characters
/// other than tab, line feed and carriage return
fn isShortText(content: []const u8) bool {
    const view = std.unicode.Utf8View.init(content) catch return false;
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint()) |c| {
        count += 1;
        if (count > render.max_value_length) return false;
        switch (c) {
            '\t', '\n', '\r' => {},
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0x9f => return false,
            else => {},
        }
    }
    return true;
}

/// A field name in an initializer (`.{ .name = x }`, `T{ .name = x }`): the field of the
/// initializer's type, with its type in that type (the field type in the instance for a generic
/// container; inside a generic function body, in a call-site instance) and its documentation
fn initFieldHover(r: *Resolver, file: FileId, tok: ast.SyntaxToken, e: Body.ExprId) resolve.Error!?Info {
    const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
    const fields = a.body.expr(e).init.fields;
    const rel = tok.offset - a.node.offset;
    const k = for (fields, 0..) |f, k| {
        if (f.name != null and rel >= f.name_range.start and rel < f.name_range.end) break k;
    } else return null;
    var field = try initFieldAt(r, a, e, k);
    // The result type is a parameter (`.{ .len = 3 }` returned as `T`): the field exists only
    // under an instance. A result type that names the field (`Pair(T)`) keeps its type in terms
    // of the parameters.
    var from: ?seed.Seed = null;
    if (field.member == null) if (a.seeded) |s| {
        const under = try initFieldAt(r, instanceOnly(a), e, k);
        if (under.member != null) {
            field = under;
            from = s;
        }
    };
    const def = try context.defOfKey(r, field.member orelse return null) orelse return null;
    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    w.print("```zig\n{s}\n```", .{try context.signature(r, def, .{ .ty = field.ty orelse .unknown }, .multi_line)}) catch return error.OutOfMemory;
    if (from) |s| {
        w.writeAll("\n\ninferred from ") catch return error.OutOfMemory;
        try writeSource(w, r, s);
    }
    if (try context.doc(r, def)) |text| w.print("\n\n{s}", .{text}) catch return error.OutOfMemory;
    return .{ .text = out.written(), .start = tok.offset, .end = tok.range().end };
}

/// The field that the `k`-th field name of the initializer `e` names at `a`, with its type
fn initFieldAt(r: *Resolver, a: context.At, e: Body.ExprId, k: usize) resolve.Error!infer.InitField {
    const t = a.initType(e) orelse return .{};
    if (t == .unknown) return .{};
    return infer.initField(r, t, try queries.namespaceOfType(r, t), k, a.body.expr(e).init.fields[k].name);
}
/// `a` with only the inference result of its instance (`a.seeded`), not the abstract one
fn instanceOnly(a: context.At) context.At {
    var x = a;
    if (a.seeded) |s| {
        x.res = s.res;
        x.seeded = null;
    }
    return x;
}
/// `error.Foo`: the error name and the expected error set, plus its documentation when the
/// current file declares it
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
