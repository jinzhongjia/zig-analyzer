//! Lint hints: code the compiler accepts but that has no effect or always gives the same result.
//! The compiler reports none of these.
//!
//! - `redundant_cast`: `@as(T, x)`, or `@intCast(x)` / `@truncate(x)` / `@floatCast(x)` with
//!   result type `T`, where `x` already has type `T`
//! - `constant_comparison`: a comparison of an integer with an integer literal outside (or at the
//!   edge of) the range of the integer's type, which gives the same result for every value
//! - `dead_errdefer`: an `errdefer` that never runs, because the function cannot return an error
//!   or no error can be returned in the rest of its block (`break` leaves the block without
//!   running it). `errdefer unreachable` and `errdefer comptime unreachable` assert exactly that,
//!   and are not reported
//!
//! A finding must hold under every build configuration and every instance, not only the analyzed
//! one. Types therefore count only when written in the source as a primitive type name: an alias
//! may name a different type on another target or with other build options (`std.posix.mode_t`,
//! `if (options.wide) u64 else u32`), and the same primitive name is the same type everywhere.
//! Inference results confirm that the types are equal and known. Generic functions and members of
//! the types they return are skipped (a cast redundant for one instance may be needed for another),
//! as are inactive code and files with syntax errors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const database = @import("../database.zig");
const Db = database.Db;
const hir = database.hir;
const sema = database.sema;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const ItemTree = @import("../syntax/ItemTree.zig");
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;
const Body = @import("../hir/Body.zig");
const ExprId = Body.ExprId;
const InternPool = @import("../sema/InternPool.zig");
const Index = InternPool.Index;
const infer = @import("../sema/infer.zig");
const seed = @import("../ide_db/seed.zig");
const inactive = @import("inactive.zig");
const Edit = @import("code_actions.zig").Edit;
const FileId = @import("../base/Vfs.zig").FileId;

/// A lint rule: corresponds to the entries of the `lint.rules` configuration; the diagnostic code
/// is `lint.<rule>`
pub const Rule = enum {
    redundant_cast,
    constant_comparison,
    dead_errdefer,

    pub fn code(rule: Rule) []const u8 {
        return switch (rule) {
            inline else => |r| "lint." ++ @tagName(r),
        };
    }
};

/// A primitive type name as written in the source (`u8`, `usize`, `f32`)
const TypeName = struct {
    buf: [16]u8 = @splat(0),
    len: u8 = 0,

    fn init(name: []const u8) ?TypeName {
        if (name.len > 16) return null;
        var t: TypeName = .{ .len = @intCast(name.len) };
        @memcpy(t.buf[0..name.len], name);
        return t;
    }

    fn slice(t: *const TypeName) []const u8 {
        return t.buf[0..t.len];
    }
};

/// A finding in a member's body; positions are relative to the member, so moving the member does
/// not recompute it
pub const Finding = struct {
    rule: Rule,
    /// The cast (`redundant_cast`), the comparison (`constant_comparison`), or the body of the
    /// `errdefer` (`dead_errdefer`)
    range: Body.Range,
    /// `redundant_cast`: the operand, which replaces the cast
    operand: Body.Range = .none,
    /// `redundant_cast`: the type of the operand; `constant_comparison`: the type of the integer
    ty: TypeName = .{},
    /// `constant_comparison`: the result of the comparison
    result: bool = false,
    /// `dead_errdefer`: the function cannot return an error at all
    no_error_return: bool = false,
};

/// A finding in a file
pub const Located = struct {
    rule: Rule,
    start: u32,
    end: u32,
    message: []const u8,
    /// Removes the redundant cast
    fix: ?Edit = null,
};

/// Byte range (both ends inclusive)
pub const Span = struct { start: u32, end: u32 };

/// Findings in the bodies of a member. Depends only on the source and inference results, not on
/// configuration.
pub const Query = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = []const Finding;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        var out: std.ArrayList(Finding) = .empty;
        try collect(&r, key, &out);
        return ctx.db.gpa.dupe(Finding, out.items);
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    pub fn bytes(v: Value) usize {
        return v.len * @sizeOf(Finding);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

/// Findings in the file, ordered by position; when `span` is not null, only those intersecting it
pub fn findings(r: *Resolver, file: FileId, span: ?Span) resolve.Error![]const Located {
    const parse = try r.ctx.get(database.syntax.ParseFile, file);
    // Half-written code: a `try` not typed yet would make an `errdefer` look dead
    if (parse.mode != .zig or parse.errors.len != 0) return &.{};
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    const root = parse.rootNode();
    const tree = try r.itemTree(file);
    var inactive_ranges: ?[]const inactive.Range = null;
    var out: std.ArrayList(Located) = .empty;
    for (tree.items, 0..) |item, i| {
        const index: u32 = @intCast(i);
        const node = try r.itemNode(file, index) orelse continue;
        if (span) |s| if (node.range().end < s.start or node.range().start > s.end) continue;
        const list = try r.ctx.get(Query, .{ .file = file, .item = item.ast_id });
        for (list) |f| {
            var start = node.offset + f.range.start;
            var end = node.offset + f.range.end;
            if (f.rule == .dead_errdefer) {
                // The whole statement, from the `errdefer` keyword
                const path = try root.coveringPath(r.arena, start);
                const stmt = for (0..path.len) |k| {
                    const n = path[path.len - 1 - k];
                    if (n.kind() == .errdefer_stmt) break n;
                } else continue;
                start = stmt.offset;
                end = stmt.range().end;
            }
            if (span) |s| if (end < s.start or start > s.end) continue;
            if (inactive_ranges == null) inactive_ranges = try inactive.ranges(r, file);
            const is_inactive = for (inactive_ranges.?) |rg| {
                if (rg.start <= start and end <= rg.end) break true;
            } else false;
            if (is_inactive) continue;
            try out.append(r.arena, .{
                .rule = f.rule,
                .start = start,
                .end = end,
                .message = try message(r.arena, text, start, f),
                .fix = if (f.rule == .redundant_cast) .{
                    .start = start,
                    .end = end,
                    .text = text[node.offset + f.operand.start .. node.offset + f.operand.end],
                } else null,
            });
        }
    }
    std.mem.sort(Located, out.items, {}, struct {
        fn lt(_: void, a: Located, b: Located) bool {
            return a.start < b.start;
        }
    }.lt);
    return out.items;
}

/// The message of finding `f`, which starts at `start` in `text`
fn message(a: Allocator, text: []const u8, start: u32, f: Finding) Allocator.Error![]const u8 {
    return switch (f.rule) {
        .redundant_cast => blk: {
            var name_end = start + 1;
            while (name_end < text.len and (std.ascii.isAlphanumeric(text[name_end]) or text[name_end] == '_')) name_end += 1;
            break :blk std.fmt.allocPrint(a, "`{s}` has no effect: the operand already has type `{s}`", .{ text[start..name_end], f.ty.slice() });
        },
        .constant_comparison => std.fmt.allocPrint(a, "comparison is always {s}: no value of type `{s}` gives another result", .{
            if (f.result) "true" else "false",
            f.ty.slice(),
        }),
        .dead_errdefer => if (f.no_error_return)
            a.dupe(u8, "`errdefer` never runs: the function cannot return an error")
        else
            a.dupe(u8, "`errdefer` never runs: no error can be returned after it in its block"),
    };
}

/// The inputs of the checks of one member
const Ctx = struct {
    r: *Resolver,
    file: FileId,
    item: u32,
    body: *const Body,
    res: *const infer.Result,
    /// The types of references before their result type coercion (see `infer.Result.uncoerced`)
    uncoerced: std.AutoHashMapUnmanaged(ExprId, Index),
    out: *std.ArrayList(Finding),

    fn ip(c: *const Ctx) *InternPool {
        return c.r.ctx.db.env.ip;
    }

    fn ty(c: *const Ctx, e: ExprId) Index {
        return c.res.exprs[@backingInt(e)].ty;
    }

    /// The type of `e` itself, before coercion to its result type
    fn ownType(c: *const Ctx, e: ExprId) Index {
        return c.uncoerced.get(e) orelse c.ty(e);
    }
};

fn collect(r: *Resolver, key: hir.OwnerKey, out: *std.ArrayList(Finding)) resolve.Error!void {
    const tree = try r.itemTree(key.file);
    const index = tree.itemOf(key.item) orelse return;
    const item = tree.items[index];
    switch (item.kind) {
        .@"fn", .@"const", .@"var", .@"test", .@"comptime" => {},
        .field, .zon => return,
    }
    if (try seed.genericRoot(r, key.file, index) != null) return;
    const body = try r.ctx.get(hir.ItemBody, key);
    const res = try r.ctx.get(sema.Infer, .{ .owner = key, .mode = .full });
    if (res.exprs.len != body.exprs.len or res.bindings.len != body.bindings.len) return;
    var c: Ctx = .{ .r = r, .file = key.file, .item = index, .body = body, .res = res, .uncoerced = .empty, .out = out };
    for (res.uncoerced) |u| try c.uncoerced.put(r.arena, u.expr, u.tv.ty);

    for (body.exprs, 0..) |e, i| {
        const id: ExprId = @fromBackingInt(@as(u32, @intCast(i)));
        switch (e) {
            .builtin_call => |call| if (std.mem.eql(u8, call.name, "@as") and call.args.len == 2) {
                const target = primitiveName(body, call.args[0]) orelse continue;
                try checkAs(&c, id, target, call.args[1]);
                try checkResultCast(&c, target, call.args[1]);
            },
            .@"return" => |operand| if (operand) |v| if (item.kind == .@"fn") {
                // With `!T`, the return type in the Body is `T`; `E!T` and `?T` give the operand
                // the result type `T` as well
                const ret = body.type_expr orelse continue;
                const payload = switch (body.expr(ret)) {
                    .error_union_type => |eu| eu.payload,
                    .optional_type => |child| child,
                    else => ret,
                };
                try checkResultCast(&c, primitiveName(body, payload) orelse continue, v);
            },
            .assign => |a| if (a.op == .equal) {
                try checkResultCast(&c, try declaredType(&c, a.lhs) orelse continue, a.rhs);
            },
            .binary => |bin| try checkComparison(&c, id, bin.op, bin.lhs, bin.rhs),
            .block => |blk| if (item.kind == .@"fn" or item.kind == .@"test") try checkErrdefers(&c, item, id, blk),
            else => {},
        }
    }
    for (body.bindings) |b| switch (b.kind) {
        .local_const, .local_var => {
            const init = b.init orelse continue;
            try checkResultCast(&c, primitiveName(body, b.ty orelse continue) orelse continue, init);
        },
        .param, .capture => {},
    };
    // Container-level `const x: u8 = @intCast(y);`
    if (item.kind == .@"const" or item.kind == .@"var") if (body.value) |v| if (body.type_expr) |t| {
        try checkResultCast(&c, primitiveName(body, t) orelse return, v);
    };
}

/// The primitive type name written at `e` (not `@"u8"`, which may name a declaration)
fn primitiveName(b: *const Body, e: ExprId) ?[]const u8 {
    const name = switch (b.expr(e)) {
        .name_ref => |n| n,
        else => return null,
    };
    if (!b.nameRefIsBuiltin(e)) return null;
    const values = std.StaticStringMap(void).initComptime(.{ .{"true"}, .{"false"}, .{"null"}, .{"undefined"} });
    if (values.has(name)) return null;
    return name;
}

/// The type of the value `e` as written at its declaration, when it is a primitive type name: a
/// parameter or variable with a type annotation, a field, or `.len` of a slice or an array
fn declaredType(c: *const Ctx, e: ExprId) resolve.Error!?[]const u8 {
    const r = c.r;
    const b = c.body;
    switch (b.expr(e)) {
        .name_ref => |name| {
            if (b.nameRefIsBuiltin(e)) return null;
            const def = try r.resolveName(c.file, c.item, b, b.expr_scopes[@backingInt(e)], name) orelse return null;
            switch (def) {
                .local => |l| {
                    const lb = try r.body(l.file, l.item);
                    const binding = lb.binding(l.binding);
                    if (binding.kind == .capture) return null;
                    return primitiveName(lb, binding.ty orelse return null);
                },
                .item => |it| return memberType(r, it.file, it.item),
                .file => return null,
            }
        },
        .field_access => |fa| {
            if (c.res.members[@backingInt(e)]) |owner| {
                const tree = try r.itemTree(owner.file);
                return memberType(r, owner.file, tree.itemOf(owner.item) orelse return null);
            }
            // The length of a slice or an array is a `usize`
            const field = fa.field orelse return null;
            if (!std.mem.eql(u8, field, "len")) return null;
            const ip = c.ip();
            const lhs = c.ty(fa.lhs);
            if (lhs == .unknown) return null;
            const is_len = switch (ip.key(lhs)) {
                .array_type => true,
                .ptr_type => |p| p.size == .slice or (p.size == .one and ip.key(p.child) == .array_type),
                else => false,
            };
            return if (is_len) "usize" else null;
        },
        else => return null,
    }
}

/// The primitive type name written as the type of a field or a container-level variable
fn memberType(r: *Resolver, file: FileId, item: u32) resolve.Error!?[]const u8 {
    const tree = try r.itemTree(file);
    switch (tree.items[item].kind) {
        .field, .@"const", .@"var" => {},
        else => return null,
    }
    const b = try r.body(file, item);
    return primitiveName(b, b.type_expr orelse return null);
}

/// An operand whose type does not come from its result type: a name or a field access (the type of
/// a literal is `comptime_int`, and a nested cast takes the result type)
fn isPlainOperand(b: *const Body, e: ExprId) bool {
    return switch (b.expr(e)) {
        .name_ref, .field_access => true,
        else => false,
    };
}

/// `@as(target, operand)` whose operand already has type `target`
fn checkAs(c: *Ctx, call: ExprId, target: []const u8, operand: ExprId) resolve.Error!void {
    if (!isPlainOperand(c.body, operand)) return;
    try report(c, call, target, operand);
}

/// `@intCast(x)` / `@truncate(x)` / `@floatCast(x)` at `e`, whose result type is written as
/// `target`, where `x` already has type `target`
fn checkResultCast(c: *Ctx, target: []const u8, e: ExprId) resolve.Error!void {
    const call = switch (c.body.expr(e)) {
        .builtin_call => |call| call,
        else => return,
    };
    const casts = std.StaticStringMap(void).initComptime(.{ .{"@intCast"}, .{"@truncate"}, .{"@floatCast"} });
    if (!casts.has(call.name) or call.args.len != 1) return;
    const operand = call.args[0];
    if (!isPlainOperand(c.body, operand)) return;
    try report(c, e, target, operand);
}

fn report(c: *Ctx, cast: ExprId, target: []const u8, operand: ExprId) resolve.Error!void {
    const declared = try declaredType(c, operand) orelse return;
    if (!std.mem.eql(u8, declared, target)) return;
    // `return @intCast(x)` with return type `?u8` coerces the result of the cast to `?u8`
    const t = c.ownType(cast);
    if (t == .unknown or c.ownType(operand) != t) return;
    try c.out.append(c.r.arena, .{
        .rule = .redundant_cast,
        .range = c.body.range(cast),
        .operand = c.body.range(operand),
        .ty = TypeName.init(target) orelse return,
    });
}

/// A fixed-width integer type name (`u8`, `i32`); `usize`, `isize` and the C types have a
/// different range on each target
fn fixedInt(name: []const u8) ?struct { signedness: std.builtin.Signedness, bits: u16 } {
    if (name.len < 2) return null;
    const signedness: std.builtin.Signedness = switch (name[0]) {
        'u' => .unsigned,
        'i' => .signed,
        else => return null,
    };
    const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
    if (bits == 0 or bits > 128 or name[1] == '0') return null;
    return .{ .signedness = signedness, .bits = bits };
}

/// The value of an integer literal, or of `-` applied to one. Values beyond the range are clamped,
/// which keeps the result of comparisons with integers of up to 128 bits.
fn literalInt(b: *const Body, e: ExprId) ?i256 {
    switch (b.expr(e)) {
        .literal => |text| {
            const value = switch (std.zig.parseNumberLiteral(text)) {
                .int => |v| v,
                .big_int => |base| blk: {
                    var digits = text;
                    if (base != .decimal) digits = digits[2..];
                    var buf: [256]u8 = undefined;
                    var n: usize = 0;
                    for (digits) |ch| if (ch != '_') {
                        if (n == buf.len) break :blk std.math.maxInt(u200);
                        buf[n] = ch;
                        n += 1;
                    };
                    break :blk std.fmt.parseInt(u200, buf[0..n], @backingInt(base)) catch std.math.maxInt(u200);
                },
                .float, .failure => return null,
            };
            return value;
        },
        .prefix => |p| {
            if (p.op != .minus) return null;
            return -(literalInt(b, p.operand) orelse return null);
        },
        else => return null,
    }
}

/// `x op literal` or `literal op x`, where `x` has a fixed-width integer type and the literal
/// decides the comparison for every value of that type
fn checkComparison(c: *Ctx, e: ExprId, op: SyntaxKind, lhs: ExprId, rhs: ExprId) resolve.Error!void {
    switch (op) {
        .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_right, .angle_bracket_right_equal => {},
        else => return,
    }
    const b = c.body;
    // Written as `x op literal`
    var value = lhs;
    var norm = op;
    var literal = literalInt(b, rhs);
    if (literal == null) {
        literal = literalInt(b, lhs);
        value = rhs;
        norm = switch (op) {
            .angle_bracket_left => .angle_bracket_right,
            .angle_bracket_left_equal => .angle_bracket_right_equal,
            .angle_bracket_right => .angle_bracket_left,
            .angle_bracket_right_equal => .angle_bracket_left_equal,
            else => op,
        };
    }
    const l = literal orelse return;
    if (!isPlainOperand(b, value)) return;
    const name = try declaredType(c, value) orelse return;
    const int = fixedInt(name) orelse return;
    // The inferred type must be that integer type
    switch (c.ip().key(c.ownType(value))) {
        .int_type => |t| if (t.signedness != int.signedness or t.bits != int.bits) return,
        else => return,
    }
    const min: i256 = if (int.signedness == .signed) -(@as(i256, 1) << @intCast(int.bits - 1)) else 0;
    const max: i256 = if (int.signedness == .signed) (@as(i256, 1) << @intCast(int.bits - 1)) - 1 else (@as(i256, 1) << @intCast(int.bits)) - 1;
    const result: bool = switch (norm) {
        .angle_bracket_left => if (l > max) true else if (l <= min) false else return,
        .angle_bracket_left_equal => if (l >= max) true else if (l < min) false else return,
        .angle_bracket_right => if (l >= max) false else if (l < min) true else return,
        .angle_bracket_right_equal => if (l <= min) true else if (l > max) false else return,
        .equal_equal => if (l < min or l > max) false else return,
        .bang_equal => if (l < min or l > max) true else return,
        else => return,
    };
    try c.out.append(c.r.arena, .{
        .rule = .constant_comparison,
        .range = b.range(e),
        .ty = TypeName.init(name) orelse return,
        .result = result,
    });
}

/// The `errdefer` statements of a block that never run: in a function whose return type is not
/// an error union or error set, or with no `try` and no `return` that may give an error after the
/// statement in the block (the `errdefer` stops applying at the end of the block)
fn checkErrdefers(c: *Ctx, item: ItemTree.Item, block: ExprId, blk: Body.Block) resolve.Error!void {
    const b = c.body;
    const no_error_return = item.kind == .@"fn" and !item.flags.inferred_error_set and if (b.type_expr) |t|
        if (primitiveName(b, t)) |name| !std.mem.eql(u8, name, "anyerror") else false
    else
        false;
    const block_end = b.range(block).end;
    for (blk.stmts) |stmt| {
        const body = switch (stmt.kind) {
            .@"errdefer" => |x| x,
            else => continue,
        };
        // `errdefer comptime unreachable;` asserts that no error is returned after it: it is
        // meant never to run
        const asserted = switch (b.expr(body)) {
            .@"unreachable" => true,
            .@"comptime" => |x| b.expr(x) == .@"unreachable",
            else => false,
        };
        if (asserted) continue;
        if (!no_error_return) {
            // Expressions in the rest of the block: a `defer` / `errdefer` body there cannot
            // contain `try` or `return`, and containers defined there keep their members out of
            // the Body
            const rest_start = stmt.end;
            const may_fail = for (b.exprs, b.expr_ranges) |x, rg| {
                if (rg.start < rest_start or rg.end > block_end) continue;
                if (mayReturnError(c, x)) break true;
            } else false;
            if (may_fail) continue;
        }
        try c.out.append(c.r.arena, .{
            .rule = .dead_errdefer,
            .range = b.range(body),
            .no_error_return = no_error_return,
        });
    }
}

/// `try`, or a `return` whose operand may be an error
fn mayReturnError(c: *const Ctx, x: Body.Expr) bool {
    switch (x) {
        .prefix => |p| return p.op == .keyword_try,
        .@"return" => |operand| {
            const v = operand orelse return false;
            return switch (c.body.expr(v)) {
                .literal, .init, .enum_literal => false,
                .name_ref, .field_access => mayBeError(c.ip(), c.ownType(v)),
                else => true,
            };
        },
        else => return false,
    }
}

/// Whether a value of type `t` may be an error (an unknown type may)
fn mayBeError(ip: *InternPool, t: Index) bool {
    if (t == .unknown or t == .anyerror_type) return true;
    return switch (ip.key(t)) {
        .error_union_type, .error_set_type, .inferred_error_set, .unknown => true,
        else => false,
    };
}

test {
    _ = @import("lint_test.zig");
}
