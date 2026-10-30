//! HIR: an error-tolerant intermediate representation of the expressions in a BodyOwner
//! (function, const/var, field, test, comptime block).
//!
//! Lowered from the CST (`lower.zig`); missing syntax becomes `.missing`. All positions are
//! relative to the start of the owner node, so edits before the owner do not change the contents
//! of the Body. Containers defined in the body are recorded only as `.container`; their members
//! belong to the ItemTree.
//!
//! Scopes are computed during lowering: each expression records the scope it is evaluated in,
//! and the scope chain holds the visible parameters, local variables, captures, and labels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;
const deepEql = @import("../util/deep_eql.zig").deepEql;

const Body = @This();

arena: std.heap.ArenaAllocator.State,
exprs: []const Expr,
/// Parallel to `exprs`
expr_ranges: []const Range,
/// Parallel to `exprs`: the scope each expression is evaluated in
expr_scopes: []const ScopeId,
bindings: []const Binding,
scopes: []const Scope,
/// Function parameters (in order)
params: []const BindingId,
/// Main part of the owner: function body, variable initializer, field default value,
/// test / comptime block
value: ?ExprId,
/// Type annotation of a variable or field; return type of a function
type_expr: ?ExprId,
/// Expression in the `align(...)` of a variable or field
align_expr: ?ExprId,
/// Expressions in the `align` / `addrspace` / `linksection` / `callconv` clauses of function
/// prototypes, variables and fields, local variables, and pointer types (the clauses are not part
/// of the expression tree; they are inferred separately, against the result type of the clause)
clauses: []const Clause,

pub const ExprId = enum(u32) { _ };
pub const BindingId = enum(u32) { _ };
pub const ScopeId = enum(u32) { root = 0, _ };

/// Byte range relative to the start of the owner
pub const Range = struct {
    start: u32,
    end: u32,

    pub const none: Range = .{ .start = 0, .end = 0 };

    pub fn contains(r: Range, offset: u32) bool {
        return r.start <= offset and offset < r.end;
    }
};

pub const Expr = union(enum) {
    /// Missing syntax
    missing,
    name_ref: []const u8,
    /// `field` is null while `foo.` is not finished yet
    field_access: struct { lhs: ExprId, field: ?[]const u8 },
    enum_literal: []const u8,
    error_value: []const u8,
    /// Number, string, and character literals, and `inf` / `nan` in ZON: the source text. For a
    /// multiline string literal, the tokens of its lines (starting with `\\`, without the newline)
    /// joined with `\n`
    literal: []const u8,
    /// `name` includes the `@`
    builtin_call: struct { name: []const u8, args: []const ExprId },
    call: struct { callee: ExprId, args: []const ExprId },
    block: Block,
    @"if": struct { cond: ExprId, capture: []const BindingId, then: ExprId, else_capture: []const BindingId, @"else": ?ExprId },
    loop: Loop,
    @"switch": struct { operand: ExprId, prongs: []const Prong },
    @"catch": struct { lhs: ExprId, capture: ?BindingId, rhs: ExprId },
    binary: struct { op: SyntaxKind, lhs: ExprId, rhs: ExprId },
    /// Includes `try`, `&`, `-`, `!`, `~`
    prefix: struct { op: SyntaxKind, operand: ExprId },
    assign: struct { op: SyntaxKind, lhs: ExprId, rhs: ExprId },
    index: struct { lhs: ExprId, index: ExprId },
    slice: struct { lhs: ExprId, start: ExprId, end: ?ExprId, sentinel: ?ExprId },
    deref: ExprId,
    unwrap_optional: ExprId,
    /// `T{ ... }` / `.{ ... }`
    init: struct { ty: ?ExprId, fields: []const FieldInit },
    /// Container defined in the body (see the ItemTree for its contents), matched by position.
    /// `arg` is the integer type of `enum(u8)`, the tag type of `union(E)`, or the backing integer
    /// of `packed struct(u32)`
    container: struct { arg: ?ExprId },
    /// Function type `fn (A, B) R`
    fn_type: struct { params: []const ExprId, ret: ?ExprId },
    @"return": ?ExprId,
    @"break": struct { label: ?[]const u8, value: ?ExprId },
    /// `continue :l value` of a labeled switch carries a value
    @"continue": struct { label: ?[]const u8, value: ?ExprId },
    @"comptime": ExprId,
    @"unreachable",
    optional_type: ExprId,
    error_union_type: struct { err: ExprId, payload: ExprId },
    ptr_type: struct { size: PtrSize, is_const: bool, child: ExprId, sentinel: ?ExprId = null },
    array_type: struct { len: ExprId, child: ExprId, sentinel: ?ExprId = null },
    error_set: []const []const u8,
    /// Other constructs (asm, nosuspend, syntax error nodes, ...): only the subexpressions are
    /// kept, so that the names in them can still be resolved
    other: []const ExprId,
};

pub const PtrSize = enum { one, many, slice, c };

pub const Clause = struct {
    kind: Kind,
    expr: ExprId,

    /// `bit_range` is for the two items after the alignment in the `align(a:b:c)` of a bit pointer
    pub const Kind = enum { @"align", bit_range, @"addrspace", @"linksection", @"callconv" };
};

pub const Block = struct {
    label: ?[]const u8,
    stmts: []const Stmt,
    /// Scope of the first statement in the block
    scope: ScopeId,
};

pub const Stmt = struct {
    kind: union(enum) {
        expr: ExprId,
        /// Local variable declaration
        local: BindingId,
        @"defer": ExprId,
        @"errdefer": struct { capture: ?BindingId, body: ExprId },
        /// `a, const b = expr;`
        destructure: struct { targets: []const DestructureTarget, value: ExprId },
    },
    /// End of the statement (relative to the owner)
    end: u32,
    /// Scope of the statements after this one
    scope_after: ScopeId,
};

pub const DestructureTarget = union(enum) { binding: BindingId, expr: ExprId };

pub const Loop = struct {
    kind: enum { @"while", @"for" },
    label: ?[]const u8,
    /// Condition of a while; inputs of a for
    inputs: []const ExprId,
    capture: []const BindingId,
    /// The `: (cont)` of a while
    cont: ?ExprId,
    body: ExprId,
    else_capture: []const BindingId,
    @"else": ?ExprId,
    is_inline: bool,
};

pub const Prong = struct {
    items: []const ExprId,
    is_else: bool,
    /// `inline` prong: each item is instantiated separately, and the capture is comptime-known
    is_inline: bool = false,
    capture: []const BindingId,
    body: ExprId,
};

pub const FieldInit = struct {
    /// The tuple form `.{ a, b }` has no field names
    name: ?[]const u8,
    value: ExprId,
    /// Position of the field name token (for find references and rename)
    name_range: Range = .none,
};

pub const Binding = struct {
    name: []const u8,
    kind: Kind,
    /// Position of the name token
    range: Range,
    /// Type annotation (parameter type, `const x: T`)
    ty: ?ExprId = null,
    /// Initializer of a local variable
    init: ?ExprId = null,
    /// `|*x|`
    is_ptr: bool = false,
    /// `comptime` parameter, or `comptime var` local variable
    is_comptime: bool = false,

    pub const Kind = enum { param, local_const, local_var, capture };
};

pub const Scope = struct {
    parent: ?ScopeId,
    bindings: []const BindingId,
    /// Labeled block, loop or switch
    label: ?struct { name: []const u8, expr: ExprId } = null,
};

pub fn deinit(b: *Body, gpa: Allocator) void {
    var arena = b.arena.promote(gpa);
    arena.deinit();
    b.* = undefined;
}

/// Structural equality (the arena is not compared): when the contents of a Body are unchanged,
/// downstream queries need not be recomputed
pub fn eql(a: *const Body, b: *const Body) bool {
    inline for (@typeInfo(Body).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "arena")) continue;
        if (!deepEql(@field(a, name), @field(b, name))) return false;
    }
    return true;
}

pub fn expr(b: *const Body, id: ExprId) Expr {
    return b.exprs[@backingInt(id)];
}

pub fn range(b: *const Body, id: ExprId) Range {
    return b.expr_ranges[@backingInt(id)];
}

/// The range of a name_ref is the raw token; a quoted or escaped identifier is longer than the
/// decoded name.
pub fn nameRefIsEscaped(b: *const Body, id: ExprId) bool {
    const span = b.range(id);
    return span.end - span.start > b.expr(id).name_ref.len;
}

/// Unquoted primitive type / primitive value name: built into the language, never resolved to a
/// declaration with the same name (`@"u32"` can be the name of a declaration)
pub fn nameRefIsBuiltin(b: *const Body, id: ExprId) bool {
    if (b.nameRefIsEscaped(id)) return false;
    const name = b.expr(id).name_ref;
    if (std.zig.primitives.isPrimitive(name)) return true;
    const values = std.StaticStringMap(void).initComptime(.{ .{"true"}, .{"false"}, .{"null"}, .{"undefined"} });
    return values.has(name);
}

pub fn binding(b: *const Body, id: BindingId) Binding {
    return b.bindings[@backingInt(id)];
}

pub fn scope(b: *const Body, id: ScopeId) Scope {
    return b.scopes[@backingInt(id)];
}

/// Smallest expression containing `offset` (relative to the owner)
pub fn exprAt(b: *const Body, offset: u32) ?ExprId {
    var best: ?ExprId = null;
    var best_len: u32 = std.math.maxInt(u32);
    for (b.expr_ranges, 0..) |r, i| {
        if (!r.contains(offset)) continue;
        if (r.end - r.start < best_len) {
            best_len = r.end - r.start;
            best = @fromBackingInt(@as(u32, @intCast(i)));
        }
    }
    return best;
}

/// Scope holding the local names visible at `offset`
pub fn scopeAt(b: *const Body, offset: u32) ScopeId {
    const e = b.exprAt(offset) orelse return .root;
    switch (b.expr(e)) {
        .block => |blk| {
            // Inside a block: take the scope after the last statement before offset
            var s = blk.scope;
            for (blk.stmts) |stmt| {
                if (stmt.end > offset) break;
                s = stmt.scope_after;
            }
            return s;
        },
        else => return b.expr_scopes[@backingInt(e)],
    }
}

/// Looks up a name along the scope chain
pub fn lookup(b: *const Body, from: ScopeId, name: []const u8) ?BindingId {
    var s: ?ScopeId = from;
    while (s) |id| : (s = b.scope(id).parent) {
        const bindings = b.scope(id).bindings;
        var i = bindings.len;
        while (i > 0) {
            i -= 1;
            const candidate = b.binding(bindings[i]);
            // A bare `_` introduces no name, while the escaped `@"_"` is still a binding that
            // can be referenced.
            if (candidate.range.end - candidate.range.start == 1 and std.mem.eql(u8, candidate.name, "_")) continue;
            if (std.mem.eql(u8, candidate.name, name)) return bindings[i];
        }
    }
    return null;
}

/// The labeled block, loop or switch that `break :name` / `continue :name` at `e` targets: the
/// innermost enclosing expression with the label (the compiler rejects redefining a label inside
/// the expression it labels)
pub fn labelTarget(b: *const Body, e: ExprId, name: []const u8) ?ExprId {
    var s: ?ScopeId = b.expr_scopes[@backingInt(e)];
    while (s) |id| : (s = b.scope(id).parent) {
        const l = b.scope(id).label orelse continue;
        if (std.mem.eql(u8, l.name, name)) return l.expr;
    }
    return null;
}

test {
    _ = @import("lower.zig");
}

/// Value of the ZON float literals `inf` and `nan` (the source text of a `literal`;
/// `std.zig.ZonGen` also decides by the source text of the identifier); null for anything else
pub fn zonFloatValue(text: []const u8) ?f128 {
    if (std.mem.eql(u8, text, "inf")) return std.math.inf(f128);
    if (std.mem.eql(u8, text, "nan")) return std.math.nan(f128);
    return null;
}

/// Value of a string literal (the source text of a `literal`, multiline string literals
/// included); null when it is not a string or has an invalid escape
pub fn stringLiteralValue(gpa: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    if (text.len == 0) return null;
    switch (text[0]) {
        '"' => return std.zig.string_literal.parseAlloc(gpa, text) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        },
        // Matches the compiler: the lines are joined with newlines after removing `\\`, with no
        // newline after the last line
        '\\' => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            var lines = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first) try out.append(gpa, '\n');
                first = false;
                try out.appendSlice(gpa, line[@min(line.len, 2)..]);
            }
            return try out.toOwnedSlice(gpa);
        },
        else => return null,
    }
}

/// Offset of byte `decoded` of the decoded contents within the source of a string literal
/// (including the quotes; for a multiline string literal, the `\\` of each line and the
/// indentation between lines); when `decoded` is the length of the contents, the offset where
/// the contents end
pub fn literalSourceOffset(src: []const u8, decoded: usize) ?usize {
    if (src.len == 0) return null;
    var d: usize = 0;
    switch (src[0]) {
        '"' => {
            var i: usize = 1;
            while (i < src.len and src[i] != '"') {
                if (d == decoded) return i;
                if (src[i] != '\\') {
                    i += 1;
                    d += 1;
                    continue;
                }
                const start = i;
                const len: usize = switch (std.zig.string_literal.parseEscapeSequence(src, &i)) {
                    .success => |c| std.unicode.utf8CodepointSequenceLength(c) catch return null,
                    .failure => return null,
                };
                if (decoded < d + len) return start;
                d += len;
            }
            return if (d == decoded) i else null;
        },
        '\\' => {
            var i: usize = 0;
            while (true) {
                if (!std.mem.startsWith(u8, src[i..], "\\\\")) return null;
                i += 2;
                const end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
                const content_end = if (end > i and src[end - 1] == '\r') end - 1 else end;
                if (decoded <= d + (content_end - i)) return i + (decoded - d);
                d += content_end - i + 1;
                if (end == src.len) return null;
                i = end + 1;
                while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
            }
        },
        else => return null,
    }
}

test literalSourceOffset {
    const cases = [_]struct { []const u8, usize, ?usize }{
        .{ "\"abc\"", 1, 2 },
        .{ "\"abc\"", 3, 4 },
        .{ "\"a\\tb\"", 2, 4 },
        .{ "\"\\u{e9}x\"", 2, 7 },
        .{ "\\\\-a, --aa\n    \\\\-b", 6, 8 },
        .{ "\\\\-a, --aa\n    \\\\-b", 8, 10 },
        .{ "\\\\-a, --aa\n    \\\\-b", 9, 17 },
        .{ "\\\\-a, --aa\n    \\\\-b", 11, 19 },
        .{ "\\\\-a, --aa\n    \\\\-b", 12, null },
        .{ "12", 0, null },
    };
    for (cases) |c| try std.testing.expectEqual(c[2], literalSourceOffset(c[0], c[1]));
}

test stringLiteralValue {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "\"a\\tb\"", "a\tb" },
        .{ "\\\\one", "one" },
        .{ "\\\\-a, --aa\n\\\\-b\n\\\\", "-a, --aa\n-b\n" },
        .{ "12", null },
    };
    for (cases) |c| {
        const v = try stringLiteralValue(gpa, c[0]);
        defer if (v) |x| gpa.free(x);
        if (c[1]) |want| try std.testing.expectEqualStrings(want, v.?) else try std.testing.expectEqual(null, v);
    }
}
