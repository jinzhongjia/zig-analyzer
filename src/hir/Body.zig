//! HIR：BodyOwner（函数、const/var、字段、test、comptime 块）中表达式的容错中间表示。
//!
//! 由 CST 降级而来（`lower.zig`），语法缺失处为 `.missing`。位置都相对于 owner 节点的起点，
//! owner 之前的编辑不改变 Body 的内容。体内定义的容器只记录为 `.container`，其成员属于 ItemTree。
//!
//! 作用域在降级时一并算出：每个表达式记录其求值时所在的作用域，作用域链上是可见的
//! 参数、局部变量、捕获与标签。

const std = @import("std");
const Allocator = std.mem.Allocator;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;
const deepEql = @import("../util/deep_eql.zig").deepEql;

const Body = @This();

arena: std.heap.ArenaAllocator.State,
exprs: []const Expr,
/// 与 `exprs` 一一对应
expr_ranges: []const Range,
/// 与 `exprs` 一一对应：表达式求值时所在的作用域
expr_scopes: []const ScopeId,
bindings: []const Binding,
scopes: []const Scope,
/// 函数参数（按顺序）
params: []const BindingId,
/// owner 的主体：函数体、变量初始化、字段默认值、test / comptime 块
value: ?ExprId,
/// 变量与字段的类型标注、函数的返回类型
type_expr: ?ExprId,
/// 变量与字段的 `align(...)` 中的表达式
align_expr: ?ExprId,
/// 函数原型、变量与字段、局部变量、指针类型的 `align` / `addrspace` / `linksection` / `callconv` 子句中的
/// 表达式（子句不属于表达式树，推导时按子句的结果类型单独推导）
clauses: []const Clause,

pub const ExprId = enum(u32) { _ };
pub const BindingId = enum(u32) { _ };
pub const ScopeId = enum(u32) { root = 0, _ };

/// 相对 owner 起点的字节区间
pub const Range = struct {
    start: u32,
    end: u32,

    pub const none: Range = .{ .start = 0, .end = 0 };

    pub fn contains(r: Range, offset: u32) bool {
        return r.start <= offset and offset < r.end;
    }
};

pub const Expr = union(enum) {
    /// 语法缺失
    missing,
    name_ref: []const u8,
    /// `foo.` 尚未写完时 `field` 为 null
    field_access: struct { lhs: ExprId, field: ?[]const u8 },
    enum_literal: []const u8,
    error_value: []const u8,
    /// 数字、字符串、字符字面量：原文。多行字符串为各行的 token（`\\` 开头，不含换行符）以 `\n` 连接
    literal: []const u8,
    /// `name` 含 `@`
    builtin_call: struct { name: []const u8, args: []const ExprId },
    call: struct { callee: ExprId, args: []const ExprId },
    block: Block,
    @"if": struct { cond: ExprId, capture: []const BindingId, then: ExprId, else_capture: []const BindingId, @"else": ?ExprId },
    loop: Loop,
    @"switch": struct { operand: ExprId, prongs: []const Prong },
    @"catch": struct { lhs: ExprId, capture: ?BindingId, rhs: ExprId },
    binary: struct { op: SyntaxKind, lhs: ExprId, rhs: ExprId },
    /// 含 `try`、`&`、`-`、`!`、`~`
    prefix: struct { op: SyntaxKind, operand: ExprId },
    assign: struct { op: SyntaxKind, lhs: ExprId, rhs: ExprId },
    index: struct { lhs: ExprId, index: ExprId },
    slice: struct { lhs: ExprId, start: ExprId, end: ?ExprId, sentinel: ?ExprId },
    deref: ExprId,
    unwrap_optional: ExprId,
    /// `T{ ... }` / `.{ ... }`
    init: struct { ty: ?ExprId, fields: []const FieldInit },
    /// 体内定义的容器（内容见 ItemTree），按位置对应。`arg` 为 `enum(u8)` 的整数类型、
    /// `union(E)` 的标签类型、`packed struct(u32)` 的 backing 整数
    container: struct { arg: ?ExprId },
    /// 函数类型 `fn (A, B) R`
    fn_type: struct { params: []const ExprId, ret: ?ExprId },
    @"return": ?ExprId,
    @"break": struct { label: ?[]const u8, value: ?ExprId },
    /// labeled switch 的 `continue :l value` 带值
    @"continue": struct { label: ?[]const u8, value: ?ExprId },
    @"comptime": ExprId,
    @"unreachable",
    optional_type: ExprId,
    error_union_type: struct { err: ExprId, payload: ExprId },
    ptr_type: struct { size: PtrSize, is_const: bool, child: ExprId, sentinel: ?ExprId = null },
    array_type: struct { len: ExprId, child: ExprId, sentinel: ?ExprId = null },
    error_set: []const []const u8,
    /// 其他结构（asm、nosuspend、语法错误节点等）：只保留子表达式，使其中的名字仍可解析
    other: []const ExprId,
};

pub const PtrSize = enum { one, many, slice, c };

pub const Clause = struct {
    kind: Kind,
    expr: ExprId,

    /// `bit_range` 为位指针 `align(a:b:c)` 中对齐之后的两项
    pub const Kind = enum { @"align", bit_range, @"addrspace", @"linksection", @"callconv" };
};

pub const Block = struct {
    label: ?[]const u8,
    stmts: []const Stmt,
    /// 块内第一条语句所在的作用域
    scope: ScopeId,
};

pub const Stmt = struct {
    kind: union(enum) {
        expr: ExprId,
        /// 局部变量声明
        local: BindingId,
        @"defer": ExprId,
        @"errdefer": struct { capture: ?BindingId, body: ExprId },
        /// `a, const b = expr;`
        destructure: struct { targets: []const DestructureTarget, value: ExprId },
    },
    /// 语句结束位置（相对 owner）
    end: u32,
    /// 本语句之后的语句所在的作用域
    scope_after: ScopeId,
};

pub const DestructureTarget = union(enum) { binding: BindingId, expr: ExprId };

pub const Loop = struct {
    kind: enum { @"while", @"for" },
    label: ?[]const u8,
    /// while 的条件；for 的各个输入
    inputs: []const ExprId,
    capture: []const BindingId,
    /// while 的 `: (cont)`
    cont: ?ExprId,
    body: ExprId,
    else_capture: []const BindingId,
    @"else": ?ExprId,
    is_inline: bool,
};

pub const Prong = struct {
    items: []const ExprId,
    is_else: bool,
    /// `inline` 分支：每个分支项单独实例化，捕获 comptime 已知
    is_inline: bool = false,
    capture: []const BindingId,
    body: ExprId,
};

pub const FieldInit = struct {
    /// 元组形式 `.{ a, b }` 没有字段名
    name: ?[]const u8,
    value: ExprId,
    /// 字段名 token 的位置（引用查找与重命名用）
    name_range: Range = .none,
};

pub const Binding = struct {
    name: []const u8,
    kind: Kind,
    /// 名字 token 的位置
    range: Range,
    /// 类型标注（参数类型、`const x: T`）
    ty: ?ExprId = null,
    /// 局部变量的初始化表达式
    init: ?ExprId = null,
    /// `|*x|`
    is_ptr: bool = false,
    /// `comptime` 参数
    is_comptime: bool = false,

    pub const Kind = enum { param, local_const, local_var, capture };
};

pub const Scope = struct {
    parent: ?ScopeId,
    bindings: []const BindingId,
    /// 带标签的块或循环
    label: ?struct { name: []const u8, expr: ExprId } = null,
};

pub fn deinit(b: *Body, gpa: Allocator) void {
    var arena = b.arena.promote(gpa);
    arena.deinit();
    b.* = undefined;
}

/// 结构相等（不比较 arena）：Body 内容不变时下游 query 不必重算
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

/// name_ref 的区间是原始 token；带引号或转义的标识符比解码后的名字更长。
pub fn nameRefIsEscaped(b: *const Body, id: ExprId) bool {
    const span = b.range(id);
    return span.end - span.start > b.expr(id).name_ref.len;
}

/// 不带引号的原始类型 / 原始值名字：语言内建，不解析到同名声明（`@"u32"` 可以同名）
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

/// 包含 `offset`（相对 owner）的最小表达式
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

/// `offset` 处可见局部名字所在的作用域
pub fn scopeAt(b: *const Body, offset: u32) ScopeId {
    const e = b.exprAt(offset) orelse return .root;
    switch (b.expr(e)) {
        .block => |blk| {
            // 块内：取 offset 之前最后一条语句之后的作用域
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

/// 沿作用域链查找名字
pub fn lookup(b: *const Body, from: ScopeId, name: []const u8) ?BindingId {
    var s: ?ScopeId = from;
    while (s) |id| : (s = b.scope(id).parent) {
        const bindings = b.scope(id).bindings;
        var i = bindings.len;
        while (i > 0) {
            i -= 1;
            const candidate = b.binding(bindings[i]);
            // 裸 `_` 不引入名字，转义后的 `@"_"` 仍是可引用的绑定。
            if (candidate.range.end - candidate.range.start == 1 and std.mem.eql(u8, candidate.name, "_")) continue;
            if (std.mem.eql(u8, candidate.name, name)) return bindings[i];
        }
    }
    return null;
}

test {
    _ = @import("lower.zig");
}

/// 字符串字面量（`literal` 的原文，含多行字符串）的值；不是字符串或转义无效时为 null
pub fn stringLiteralValue(gpa: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    if (text.len == 0) return null;
    switch (text[0]) {
        '"' => return std.zig.string_literal.parseAlloc(gpa, text) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        },
        // 与编译器一致：各行去掉 `\\` 后以换行符连接，最后一行之后没有换行符
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

/// 字符串字面量的源码（含引号；多行字符串含各行的 `\\` 与行间缩进）中，解码后的内容第 `decoded` 个字节
/// 所在的位置；`decoded` 为内容长度时为内容结束处
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
