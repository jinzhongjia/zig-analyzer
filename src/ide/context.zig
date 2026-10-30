//! Shared parts of the IDE features: the member at the cursor, its Body and inference result;
//! signatures and documentation of definitions.

const std = @import("std");
const database = @import("../database.zig");
const hir = database.hir;
const sema = database.sema;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ast = @import("../syntax/ast.zig");
const SyntaxNode = ast.SyntaxNode;
const Body = @import("../hir/Body.zig");
const infer = @import("../sema/infer.zig");
const eval = @import("../sema/eval.zig");
const render = @import("../sema/render.zig");
const InternPool = @import("../sema/InternPool.zig");
const TypedValue = InternPool.TypedValue;
const Index = InternPool.Index;
const seed = @import("../ide_db/seed.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const At = struct {
    file: FileId,
    item: u32,
    node: SyntaxNode,
    owner: hir.OwnerKey,
    body: *const Body,
    res: *const infer.Result,
    /// Position relative to the start of the member
    rel: u32,
    ip: *InternPool,
    /// Inference result for a call-site instance when the member is in a generic function (see
    /// `atSeeded`): parts of `res` that contain abstract parameters or are unknown come from here
    seeded: ?seed.Seed = null,

    pub fn exprType(a: At, e: Body.ExprId) TypedValue {
        return a.better(a.res.exprs, if (a.seeded) |s| s.res.exprs else &.{}, @backingInt(e));
    }

    /// Value of a reference or builtin call before its result type coercion (see
    /// `infer.Result.uncoerced`)
    pub fn uncoercedType(a: At, e: Body.ExprId) TypedValue {
        const tv = a.res.uncoercedValue(e);
        if (a.seeded) |s| {
            const better_tv = s.res.uncoercedValue(e);
            if (seed.wanted(a.ip, tv) and !seed.wanted(a.ip, better_tv)) return better_tv;
        }
        return tv;
    }

    pub fn bindingType(a: At, b: Body.BindingId) TypedValue {
        return a.better(a.res.bindings, if (a.seeded) |s| s.res.bindings else &.{}, @backingInt(b));
    }

    fn better(a: At, abstract: []const TypedValue, seeded: []const TypedValue, i: u32) TypedValue {
        const tv: TypedValue = if (i < abstract.len) abstract[i] else .unknown;
        if (i < seeded.len and seed.wanted(a.ip, tv) and !seed.wanted(a.ip, seeded[i])) return seeded[i];
        return tv;
    }

    /// Expected type of an enum literal (null when there is no expected type)
    pub fn literalExpected(a: At, e: Body.ExprId) ?Index {
        for (a.res.literal_expected) |x| if (x.expr == e) return x.ty;
        if (a.seeded) |s| for (s.res.literal_expected) |x| if (x.expr == e) return x.ty;
        return null;
    }

    /// Whether the expected type of an enum literal comes from peer type resolution (see
    /// `infer.Result.LiteralExpected.tags_only`): it names only tags, not declarations
    pub fn literalTagsOnly(a: At, e: Body.ExprId) bool {
        for (a.res.literal_expected) |x| if (x.expr == e) return x.tags_only;
        if (a.seeded) |s| for (s.res.literal_expected) |x| if (x.expr == e) return x.tags_only;
        return false;
    }

    /// Field that the `index`-th field name in the initializer `init` resolves to
    pub fn fieldRef(a: At, init: Body.ExprId, index: u32) ?hir.OwnerKey {
        for (a.res.field_refs) |f| if (f.init == init and f.index == index) return f.member;
        if (a.seeded) |s| for (s.res.field_refs) |f| if (f.init == init and f.index == index) return f.member;
        return null;
    }

    /// Type of the initializer `e`, the same as in inference: the written type, or the result
    /// type with error union and optional stripped (the type recorded for the expression itself
    /// has already been converted to the result type). Null for `.{ ... }` without a result type
    /// (an anonymous struct, whose field types are just the types of the values)
    pub fn initType(a: At, e: Body.ExprId) ?Index {
        const init = a.body.expr(e).init;
        if (init.ty) |te| return a.exprType(te).asType();
        var want = a.literalExpected(e) orelse return null;
        if (a.ip.key(want) == .error_union_type) want = a.ip.key(want).error_union_type.payload;
        if (a.ip.key(want) == .optional_type) want = a.ip.key(want).optional_type;
        return want;
    }

    pub fn member(a: At, e: Body.ExprId) ?hir.OwnerKey {
        const i = @backingInt(e);
        if (i < a.res.members.len) if (a.res.members[i]) |m| return m;
        if (a.seeded) |s| if (i < s.res.members.len) return s.res.members[i];
        return null;
    }
};

pub fn at(r: *Resolver, file: FileId, offset: u32, inclusive_end: bool) resolve.Error!?At {
    const item = try r.ownerAt(file, offset, inclusive_end) orelse return null;
    var a = try atItem(r, file, item) orelse return null;
    a.rel = offset - a.node.offset;
    return a;
}

/// Same as `at`; when the member is inside a generic function, also attaches the inference result
/// of a call-site instance (`At.seeded`). The instance must make the code at the position execute
/// and the expression there have a known type (see `subjectAt`)
pub fn atSeeded(r: *Resolver, file: FileId, offset: u32, inclusive_end: bool) resolve.Error!?At {
    var a = try at(r, file, offset, inclusive_end) orelse return null;
    const subject = subjectAt(a.body, a.rel, inclusive_end);
    var refiner = try seed.Refiner.init(r, a.file, a.item, a.node.offset, a.body, a.res);
    a.seeded = try refiner.at(a.rel, subject);
    return a;
}

/// `a` under every call-site instance of the generic function containing its member (and every
/// iteration of a region inferred per iteration; see `seed.allSeeds`): one `At` per inference
/// result, with `seeded` set to it
pub fn allSeeded(r: *Resolver, a: At) resolve.Error![]const At {
    const seeds = try seed.allSeeds(r, a.file, a.item, a.body, a.res, a.rel);
    const out = try r.arena.alloc(At, seeds.len);
    for (seeds, out) |s, *x| {
        x.* = a;
        x.seeded = s;
    }
    return out;
}

/// Expression at the position whose type must be known: the left-hand side when the position is
/// on the member name of a member access, otherwise the expression containing it. With
/// `inclusive_end`, the position is right after just-typed text (completion), so the expression
/// at the previous character is taken (such as the `.` of `a.`)
fn subjectAt(b: *const Body, rel: u32, inclusive_end: bool) ?seed.Subject {
    const at_ = if (inclusive_end and rel > 0) rel - 1 else rel;
    const e = b.exprAt(at_) orelse return null;
    return switch (b.expr(e)) {
        .field_access => |fa| .{ .expr = if (at_ >= b.range(fa.lhs).end) fa.lhs else e },
        else => .{ .expr = e },
    };
}

/// Definition of a member recorded in an inference result (by AstId)
pub fn defOfKey(r: *Resolver, key: hir.OwnerKey) resolve.Error!?Def {
    const tree = try r.itemTree(key.file);
    for (tree.items, 0..) |it, i| if (it.ast_id == key.item) return .{ .item = .{ .file = key.file, .item = @intCast(i) } };
    return null;
}

pub fn doc(r: *Resolver, def: Def) resolve.Error!?[]const u8 {
    return switch (def) {
        .item => |it| (try r.itemTree(it.file)).items[it.item].doc,
        else => null,
    };
}

/// Signature of a definition: the prototype for functions (see `ast.FnProto.writeSignature`), the
/// `const name: T = v` form for everything else
pub fn signature(r: *Resolver, def: Def, tv: TypedValue) resolve.Error![]const u8 {
    const ip = r.ctx.db.env.ip;
    switch (def) {
        .item => |it| {
            const tree = try r.itemTree(it.file);
            const item = tree.items[it.item];
            const node = try r.itemNode(it.file, it.item) orelse return render.typeAlloc(r, tv.ty);
            if (item.kind == .@"fn") if (ast.cast(ast.FnDecl, node)) |f| if (f.proto()) |p| {
                var out: std.Io.Writer.Allocating = .init(r.arena);
                if (item.flags.is_pub) out.writer.writeAll("pub ") catch return error.OutOfMemory;
                p.writeSignature(&out.writer) catch return error.OutOfMemory;
                return out.written();
            };
            const keyword = switch (item.kind) {
                .@"const" => "const ",
                .@"var" => "var ",
                else => "",
            };
            const name = if (item.name) |n| try std.fmt.allocPrint(r.arena, "{f}", .{std.zig.fmtId(n)}) else "_";
            // Container definition: `const S = struct`; an alias of a container is shown with the
            // aliased type (`const T: type = S`)
            if (tv.asType()) |t| switch (ip.key(t)) {
                .container_type => |c| if (try render.declaresContainer(r, c, it.file, it.item)) return std.fmt.allocPrint(r.arena, "{s}{s} = {t}", .{ keyword, name, c.kind }),
                else => {},
            };
            if (try embedOf(r, def, tv)) |e| return std.fmt.allocPrint(r.arena, "{s}{s}: {s}", .{ keyword, name, try render.embedAlloc(r, tv.ty, e.path) });
            return std.fmt.allocPrint(r.arena, "{s}{s}{s}", .{ keyword, name, try render.annotationAlloc(r, tv) });
        },
        .local => |l| {
            const b = (try r.body(l.file, l.item)).binding(l.binding);
            const keyword = switch (b.kind) {
                .local_const => "const ",
                .local_var => "var ",
                .param, .capture => "",
            };
            if (try embedOf(r, def, tv)) |e| return std.fmt.allocPrint(r.arena, "{s}{f}: {s}", .{ keyword, std.zig.fmtId(b.name), try render.embedAlloc(r, tv.ty, e.path) });
            return std.fmt.allocPrint(r.arena, "{s}{f}{s}", .{ keyword, std.zig.fmtId(b.name), try render.annotationAlloc(r, tv) });
        },
        .file => |f| return std.fmt.allocPrint(r.arena, "@import(\"{s}\")", .{std.fs.path.basename(r.ctx.db.env.vfs.path(f))}),
    }
}

/// A value that is directly the result of `@embedFile(path)`
pub const Embed = struct {
    /// The path argument
    path: []const u8,
    /// The file read
    file: FileId,
    /// Its content
    text: []const u8,
};

/// The `@embedFile` call a definition of type and value `tv` is initialized with
/// (`const x = @embedFile("a.bin")`, also with a type annotation the content coerces to, such as
/// `[]const u8`); null for any other initializer (a slice of the content, a concatenation, an
/// alias), for a variable whose value is not known at comptime, or when the path or the file
/// cannot be resolved
pub fn embedOf(r: *Resolver, def: Def, tv: TypedValue) resolve.Error!?Embed {
    const file, const item, const is_const, const init = switch (def) {
        .item => |it| blk: {
            const kind = (try r.itemTree(it.file)).items[it.item].kind;
            if (kind != .@"const" and kind != .@"var") return null;
            break :blk .{ it.file, it.item, kind == .@"const", (try r.body(it.file, it.item)).value orelse return null };
        },
        .local => |l| blk: {
            const b = (try r.body(l.file, l.item)).binding(l.binding);
            break :blk .{ l.file, l.item, b.kind == .local_const, b.init orelse return null };
        },
        .file => return null,
    };
    if (tv.val == null and !is_const) return null;
    const embed = try embedCall(r, try atItem(r, file, item) orelse return null, init) orelse return null;
    // The value of a constant with a type annotation other than `*const [len:0]u8` is not kept:
    // the call is shown when the content coerces to the type
    if (tv.val == null and !holdsContent(r.ctx.db.env.ip, tv.ty, embed.text.len)) return null;
    return embed;
}

/// Whether the content of a file of `len` bytes (`*const [len:0]u8`) coerces to `ty`: a const
/// slice or many-item pointer of `u8`, a const pointer to an array of `len` bytes, with no
/// sentinel or a zero one, or an optional of one of them
fn holdsContent(ip: *InternPool, ty: Index, len: usize) bool {
    const t = switch (ip.key(ty)) {
        .optional_type => |child| child,
        else => ty,
    };
    const p = switch (ip.key(t)) {
        .ptr_type => |p| p,
        else => return false,
    };
    if (!p.is_const or !zeroOrNone(ip, p.sentinel)) return false;
    return switch (p.size) {
        .slice, .many => p.child == .u8_type,
        .one => switch (ip.key(p.child)) {
            .array_type => |a| a.child == .u8_type and a.len == len and zeroOrNone(ip, a.sentinel),
            else => false,
        },
        .c => false,
    };
}

fn zeroOrNone(ip: *InternPool, sentinel: ?Index) bool {
    const s = sentinel orelse return true;
    return switch (ip.key(s)) {
        .int_value => |i| i.value == 0,
        else => false,
    };
}

/// The `@embedFile` call `e` (in the body of `a`) with its path resolved and the file read; null
/// for other expressions, or when the path is not known at comptime or the file does not exist
pub fn embedCall(r: *Resolver, a: At, e: Body.ExprId) resolve.Error!?Embed {
    const call = switch (a.body.expr(e)) {
        .builtin_call => |c| c,
        else => return null,
    };
    if (!std.mem.eql(u8, call.name, "@embedFile") or call.args.len != 1) return null;
    const arg = call.args[0];
    const path = switch (a.body.expr(arg)) {
        .literal => |text| if (text.len > 0 and text[0] == '"') std.zig.string_literal.parseAlloc(r.arena, text) catch null else null,
        else => null,
    } orelse try eval.stringValue(r, a.exprType(arg)) orelse return null;
    const embedded = try eval.embeddedFile(r, a.file, path) orelse return null;
    return .{ .path = path, .file = embedded.file, .text = embedded.text };
}

/// Target function of a call: returns the function declaration and whether it is a method call
/// (which skips the self parameter)
pub fn callee(r: *Resolver, a: At, callee_e: Body.ExprId) resolve.Error!?struct { def: Def, bound: bool } {
    const b = a.body;
    switch (b.expr(callee_e)) {
        .name_ref => |name| {
            const def = try r.resolveName(a.file, a.item, b, b.expr_scopes[@backingInt(callee_e)], name) orelse return null;
            return .{ .def = try fnDecl(r, a, callee_e, def), .bound = false };
        },
        .field_access => |fa| {
            const key = a.member(callee_e) orelse return null;
            const def = try defOfKey(r, key) orelse return null;
            // It is a method call only when the member is a declaration whose value is a function
            // (including an alias such as `pub const put = putImpl;`) and the left-hand side is a
            // value (not a type): fields of function type do not bind a receiver
            const method = switch (def) {
                .item => |it| switch ((try r.itemTree(it.file)).items[it.item].kind) {
                    .@"fn" => true,
                    .@"const" => a.ip.key(a.exprType(callee_e).ty) == .fn_type,
                    else => false,
                },
                else => false,
            };
            return .{ .def = try fnDecl(r, a, callee_e, def), .bound = method and !a.exprType(fa.lhs).isType() };
        },
        .enum_literal => {
            const key = a.member(callee_e) orelse return null;
            return .{ .def = try fnDecl(r, a, callee_e, try defOfKey(r, key) orelse return null), .bound = false };
        },
        else => return null,
    }
}

/// When the called name is an alias (`const assert = std.debug.assert;`, including local
/// constants), takes the function declaration it points to: first follows the alias chain of
/// container members, and when that is still not a function, takes the declaration of the
/// inferred function value
fn fnDecl(r: *Resolver, a: At, callee_e: Body.ExprId, def: Def) resolve.Error!Def {
    const target = try r.aliasTarget(def);
    switch (target) {
        .item => |it| if ((try r.itemTree(it.file)).items[it.item].kind == .@"fn") return target,
        .local, .file => {},
    }
    const v = a.exprType(callee_e).val orelse return target;
    return switch (r.ctx.db.env.ip.key(v)) {
        .fn_value => |f| try defOfKey(r, .{ .file = f.file, .item = f.decl }) orelse target,
        else => target,
    };
}

/// Prototype of the function a call invokes, for its signature and parameter names
pub const CallProto = struct {
    proto: ast.FnProto,
    /// The definition whose documentation describes the call: the called function, or the
    /// declaration (such as a field) of the function-typed value
    def: ?Def,
    /// A method call through a value: the first parameter is bound to the receiver
    bound: bool,

    /// Parameter nodes (in order)
    pub fn params(c: CallProto, arena: std.mem.Allocator) error{OutOfMemory}![]const ast.Param {
        var out: std.ArrayList(ast.Param) = .empty;
        var it = c.proto.params();
        while (it.next()) |p| try out.append(arena, ast.cast(ast.Param, p).?);
        return out.items;
    }
};

/// The called function declaration (see `callee`); for a value of function type (a function
/// pointer, a field of a vtable, a callback parameter or capture), the `fn (...)` type expression
/// its declaration is typed with, which carries the parameter names, or the function declaration
/// it is initialized with (`const f = &add;`)
pub fn callProto(r: *Resolver, a: At, callee_e: Body.ExprId) resolve.Error!?CallProto {
    if (try callee(r, a, callee_e)) |t| if (try declProto(r, t.def)) |p|
        return .{ .proto = p, .def = t.def, .bound = t.bound };
    const found = try valueProto(r, a, callee_e, 0) orelse return null;
    return .{ .proto = found.proto, .def = found.def, .bound = false };
}

/// Prototype of a function declaration
fn declProto(r: *Resolver, def: Def) resolve.Error!?ast.FnProto {
    const it = switch (def) {
        .item => |x| x,
        else => return null,
    };
    const node = try r.itemNode(it.file, it.item) orelse return null;
    return (ast.cast(ast.FnDecl, node) orelse return null).proto();
}

const Found = struct { proto: ast.FnProto, def: ?Def };

/// Bound on the declarations and aliases followed, against cycles (`const A = B; const B = A;`)
const max_hops = 64;

/// Prototype declaring the function type of the value of `e` (in the body of `a`): through names
/// and member accesses to their declarations, `&f`, `p.*` and `o.?`
fn valueProto(r: *Resolver, a: At, e: Body.ExprId, hops: u32) resolve.Error!?Found {
    if (hops > max_hops) return null;
    const b = a.body;
    switch (b.expr(e)) {
        .name_ref => |name| {
            if (Body.nameRefIsBuiltin(b, e)) return null;
            const def = try r.resolveName(a.file, a.item, b, b.expr_scopes[@backingInt(e)], name) orelse return null;
            return defProto(r, a, def, hops + 1);
        },
        .field_access => return defProto(r, a, try defOfKey(r, a.member(e) orelse return null) orelse return null, hops + 1),
        .prefix => |p| return if (p.op == .ampersand) valueProto(r, a, p.operand, hops + 1) else null,
        .deref, .unwrap_optional, .@"comptime" => |inner| return valueProto(r, a, inner, hops + 1),
        else => return null,
    }
}

/// Prototype declaring the function type of a declaration's value: a function declaration
/// itself; otherwise its type annotation, or, without one, its initializer (a capture takes the
/// operand it unwraps)
fn defProto(r: *Resolver, a: At, def: Def, hops: u32) resolve.Error!?Found {
    if (hops > max_hops) return null;
    switch (def) {
        .item => |it| {
            if (try declProto(r, def)) |p| return .{ .proto = p, .def = def };
            const kind = (try r.itemTree(it.file)).items[it.item].kind;
            if (kind != .@"const" and kind != .@"var" and kind != .field) return null;
            const at_item = try atItem(r, it.file, it.item) orelse return null;
            const b = at_item.body;
            var found = if (b.type_expr) |t|
                try typeProto(r, at_item, t, hops + 1)
            else if (kind != .field) if (b.value) |v| try valueProto(r, at_item, v, hops + 1) else null else null;
            if (found) |*f| if (f.def == null) {
                f.def = def;
            };
            return found;
        },
        .local => |l| {
            const at_item = if (l.file == a.file and l.item == a.item) a else try atItem(r, l.file, l.item) orelse return null;
            const binding = at_item.body.binding(l.binding);
            if (binding.ty) |t| return typeProto(r, at_item, t, hops + 1);
            if (binding.init) |v| return valueProto(r, at_item, v, hops + 1);
            if (binding.kind == .capture) if (captureOperand(at_item.body, l.binding)) |v| return valueProto(r, at_item, v, hops + 1);
            return null;
        },
        .file => return null,
    }
}

/// The operand whose payload a capture binds: the condition of `if` / `while` (`|cb|` of
/// `if (o.on_done)`), the input of `for` (`typeProto` strips the optional, pointer or array)
fn captureOperand(b: *const Body, binding: Body.BindingId) ?Body.ExprId {
    for (b.exprs) |e| switch (e) {
        .@"if" => |x| if (std.mem.indexOfScalar(Body.BindingId, x.capture, binding) != null) return x.cond,
        .loop => |l| if (std.mem.indexOfScalar(Body.BindingId, l.capture, binding)) |i| return switch (l.kind) {
            .@"while" => if (l.inputs.len > 0) l.inputs[0] else null,
            .@"for" => if (i < l.inputs.len) l.inputs[i] else null,
        },
        else => {},
    };
    return null;
}

/// Prototype of the function type that the type expression `e` denotes: the `fn (...)` syntax,
/// through pointers, optionals, error unions, arrays and aliases of types
fn typeProto(r: *Resolver, a: At, e: Body.ExprId, hops: u32) resolve.Error!?Found {
    if (hops > max_hops) return null;
    const b = a.body;
    switch (b.expr(e)) {
        .fn_type => {
            const node = nodeAt(a.node, a.node.offset + b.range(e).start, .fn_proto) orelse return null;
            return .{ .proto = .{ .syntax = node }, .def = null };
        },
        .ptr_type => |p| return typeProto(r, a, p.child, hops + 1),
        .array_type => |arr| return typeProto(r, a, arr.child, hops + 1),
        .optional_type, .@"comptime" => |inner| return typeProto(r, a, inner, hops + 1),
        .error_union_type => |eu| return typeProto(r, a, eu.payload, hops + 1),
        .name_ref, .field_access => {
            const def = (if (b.expr(e) == .name_ref) blk: {
                if (Body.nameRefIsBuiltin(b, e)) return null;
                break :blk try r.resolveName(a.file, a.item, b, b.expr_scopes[@backingInt(e)], b.expr(e).name_ref);
            } else blk: {
                const fa = b.expr(e).field_access;
                const ns = try r.evalNamespace(a.file, a.item, b, fa.lhs) orelse return null;
                break :blk try r.memberDef(ns, fa.field orelse return null);
            }) orelse return null;
            // An alias of a type: the type expression it is initialized with
            switch (def) {
                .item => |it| {
                    if ((try r.itemTree(it.file)).items[it.item].kind != .@"const") return null;
                    const at_item = try atItem(r, it.file, it.item) orelse return null;
                    return typeProto(r, at_item, at_item.body.value orelse return null, hops + 1);
                },
                .local => |l| {
                    const at_item = if (l.file == a.file and l.item == a.item) a else try atItem(r, l.file, l.item) orelse return null;
                    const binding = at_item.body.binding(l.binding);
                    if (binding.kind != .local_const) return null;
                    return typeProto(r, at_item, binding.init orelse return null, hops + 1);
                },
                .file => return null,
            }
        },
        else => return null,
    }
}

/// The node of `kind` that starts at `offset` among the descendants of `node`
fn nodeAt(node: SyntaxNode, offset: u32, kind: ast.SyntaxKind) ?SyntaxNode {
    if (node.offset == offset and node.kind() == kind) return node;
    var it = node.children();
    while (it.nextNode()) |c| {
        const range = c.range();
        if (range.start <= offset and offset < range.end) return nodeAt(c, offset, kind);
    }
    return null;
}

/// `At` for the whole member `item` (its Body and inference result)
fn atItem(r: *Resolver, file: FileId, item: u32) resolve.Error!?At {
    const node = try r.itemNode(file, item) orelse return null;
    const owner = try r.ownerKey(file, item);
    return .{
        .file = file,
        .item = item,
        .node = node,
        .owner = owner,
        .body = try r.ctx.get(hir.ItemBody, owner),
        .res = try r.ctx.get(sema.Infer, .{ .owner = owner, .mode = .full }),
        .rel = 0,
        .ip = r.ctx.db.env.ip,
    };
}

test {
    _ = @import("ide_test.zig");
}
