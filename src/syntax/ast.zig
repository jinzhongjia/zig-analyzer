//! 类型化 AST 访问层：在 CST 之上按语义访问子结构（设计 §5.1）。
//!
//! 「某信息位于哪个子节点」的知识集中在这里，调用方写 `decl.proto().?.name()` 而不是数子节点；
//! 语法树结构调整时只改这一处。所有访问器返回可选值：容错解析的树中任何部分都可能缺失。
//! 表达式不区分具体种类，统一用 `SyntaxNode`，由使用方按 `kind()` 分派。

const std = @import("std");
const tree = @import("tree.zig");
const kind_mod = @import("kind.zig");
pub const SyntaxNode = tree.SyntaxNode;
pub const SyntaxToken = tree.SyntaxToken;
pub const SyntaxKind = kind_mod.SyntaxKind;

/// 节点是 `T` 的种类时转换为 `T`
pub fn cast(comptime T: type, n: SyntaxNode) ?T {
    return if (n.kind() == T.kind) .{ .syntax = n } else null;
}

/// 第一个种类为 `T` 的直接子节点
fn child(n: SyntaxNode, comptime T: type) ?T {
    return if (n.childNode(T.kind)) |c| .{ .syntax = c } else null;
}

/// 第 `index` 个直接子节点
fn nthNode(n: SyntaxNode, index: usize) ?SyntaxNode {
    var it = n.children();
    var i: usize = 0;
    while (it.nextNode()) |c| : (i += 1) if (i == index) return c;
    return null;
}

/// 第一个出现在 `token` 之后的直接子节点
fn nodeAfter(n: SyntaxNode, token: SyntaxKind) ?SyntaxNode {
    var it = n.children();
    var seen = false;
    while (it.next()) |e| switch (e) {
        .token => |t| if (t.kind == token) {
            seen = true;
        },
        .node => |c| if (seen) return c,
    };
    return null;
}

/// 第一个不属于 `skip` 中种类的直接子节点
fn firstNodeExcept(n: SyntaxNode, skip: []const SyntaxKind) ?SyntaxNode {
    var it = n.children();
    while (it.nextNode()) |c| {
        if (std.mem.indexOfScalar(SyntaxKind, skip, c.kind()) == null) return c;
    }
    return null;
}

/// `token` 之后、第一个不属于 `skip` 中种类的直接子节点
fn nodeAfterExcept(n: SyntaxNode, token: SyntaxKind, skip: []const SyntaxKind) ?SyntaxNode {
    var it = n.children();
    var seen = false;
    while (it.next()) |e| switch (e) {
        .token => |t| if (t.kind == token) {
            seen = true;
        },
        .node => |c| if (seen and std.mem.indexOfScalar(SyntaxKind, skip, c.kind()) == null) return c,
    };
    return null;
}

/// 直接子节点迭代器（可按种类过滤）
pub const Nodes = struct {
    inner: SyntaxNode.Children,
    only: ?SyntaxKind = null,
    skip: ?SyntaxKind = null,

    pub fn next(it: *Nodes) ?SyntaxNode {
        while (it.inner.nextNode()) |c| {
            if (it.only) |k| if (c.kind() != k) continue;
            if (it.skip) |k| if (c.kind() == k) continue;
            return c;
        }
        return null;
    }
};

fn nodes(n: SyntaxNode) Nodes {
    return .{ .inner = n.children() };
}

// ── 容器与声明 ───────────────────────────────────────────────────────

/// 容器成员：fn_decl、var_decl、container_field、test_decl、comptime_decl
pub fn isMember(k: SyntaxKind) bool {
    return switch (k) {
        .fn_decl, .var_decl, .container_field, .test_decl, .comptime_decl => true,
        else => false,
    };
}

/// 标识符的名字：`@"name"` 形式去掉引号（含转义的保留原文）。语义层（名字解析、字段、枚举成员）
/// 一律使用去掉引号的名字，显示时再按需加回（`std.zig.fmtId`）
pub fn identName(text: []const u8) []const u8 {
    if (text.len >= 3 and text[0] == '@' and text[1] == '"' and text[text.len - 1] == '"') {
        const inner = text[2 .. text.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    }
    return text;
}

/// 容器成员的名字 token：函数名、变量名、字段名、test 名（字符串或标识符）；没有名字时为 null。
/// 枚举成员与联合的 void 字段可以没有冒号，名字在类型表达式的位置，需要由调用方说明（`in_enum`）
pub fn memberName(member: SyntaxNode, in_enum: bool) ?SyntaxToken {
    return switch (member.kind()) {
        .fn_decl => if ((FnDecl{ .syntax = member }).proto()) |p| p.name() else null,
        .var_decl => (VarDecl{ .syntax = member }).name(),
        .container_field => blk: {
            const f = ContainerField{ .syntax = member };
            break :blk if (in_enum) f.enumName() else f.name();
        },
        .test_decl => member.childToken(.string_literal) orelse member.childToken(.identifier),
        else => null,
    };
}

pub const SourceFile = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .source_file;
};

pub const ContainerDecl = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .container_decl;

    pub const Keyword = enum { @"struct", @"enum", @"union", @"opaque" };

    pub fn keyword(n: ContainerDecl) ?Keyword {
        var it = n.syntax.children();
        while (it.next()) |e| switch (e.kind()) {
            .keyword_struct => return .@"struct",
            .keyword_enum => if (n.syntax.childToken(.keyword_union) == null) return .@"enum",
            .keyword_union => return .@"union",
            .keyword_opaque => return .@"opaque",
            .l_brace => return null,
            else => {},
        };
        return null;
    }

    /// `enum(u8)` 的整数类型、`union(E)` 的标签类型
    pub fn argExpr(n: ContainerDecl) ?SyntaxNode {
        return nodeAfter(n.syntax, .l_paren);
    }
};

pub const FnDecl = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .fn_decl;

    pub fn proto(n: FnDecl) ?FnProto {
        return child(n.syntax, FnProto);
    }

    pub fn body(n: FnDecl) ?Block {
        return child(n.syntax, Block);
    }
};

pub const FnProto = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .fn_proto;

    pub fn name(n: FnProto) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }

    pub fn params(n: FnProto) Nodes {
        const list = n.syntax.childNode(.param_list) orelse return .{ .inner = .{ .elems = &.{}, .offset = 0 } };
        return .{ .inner = list.children(), .only = .param };
    }

    pub fn returnType(n: FnProto) ?SyntaxNode {
        var it = n.syntax.children();
        var last: ?SyntaxNode = null;
        while (it.nextNode()) |c| switch (c.kind()) {
            .param_list, .align_clause, .addrspace_clause, .linksection_clause, .callconv_clause => {},
            else => last = c,
        };
        return last;
    }

    /// `!T`：返回类型带推导的错误集
    pub fn inferredErrorSet(n: FnProto) bool {
        return n.syntax.childToken(.bang) != null;
    }

    /// 子句（align / addrspace / linksection / callconv）中的表达式
    pub fn clauses(n: FnProto) [4]?SyntaxNode {
        var out: [4]?SyntaxNode = @splat(null);
        for ([_]SyntaxKind{ .align_clause, .addrspace_clause, .linksection_clause, .callconv_clause }, &out) |k, *o| {
            if (n.syntax.childNode(k)) |c| o.* = c;
        }
        return out;
    }
};

pub const Param = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .param;

    pub fn name(n: Param) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }

    /// `anytype` 与 `...` 没有类型表达式
    pub fn typeExpr(n: Param) ?SyntaxNode {
        return nthNode(n.syntax, 0);
    }

    pub fn isComptime(n: Param) bool {
        return n.syntax.childToken(.keyword_comptime) != null;
    }
};

pub const VarDecl = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .var_decl;

    pub fn name(n: VarDecl) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }

    pub fn isConst(n: VarDecl) bool {
        return n.syntax.childToken(.keyword_var) == null;
    }

    pub fn typeExpr(n: VarDecl) ?SyntaxNode {
        if (n.syntax.childToken(.colon) == null) return null;
        return nodeAfter(n.syntax, .colon);
    }

    pub fn initExpr(n: VarDecl) ?SyntaxNode {
        return nodeAfter(n.syntax, .equal) orelse nodeAfter(n.syntax, .equal_equal);
    }
};

pub const ContainerField = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .container_field;

    /// 元组字段没有名字
    pub fn name(n: ContainerField) ?SyntaxToken {
        if (n.syntax.childToken(.colon) == null) return null;
        return n.syntax.childToken(.identifier);
    }

    pub fn typeExpr(n: ContainerField) ?SyntaxNode {
        return firstNodeExcept(n.syntax, &.{.align_clause});
    }

    /// 枚举成员 `red` / `red = 1`：名字位于类型表达式的位置
    pub fn enumName(n: ContainerField) ?SyntaxToken {
        if (n.name()) |t| return t;
        const first = cast(NameRef, n.typeExpr() orelse return null) orelse return null;
        return first.name();
    }

    pub fn defaultValue(n: ContainerField) ?SyntaxNode {
        return nodeAfter(n.syntax, .equal);
    }
};

pub const TestDecl = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .test_decl;

    pub fn body(n: TestDecl) ?Block {
        return child(n.syntax, Block);
    }
};

pub const ComptimeDecl = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .comptime_decl;

    pub fn body(n: ComptimeDecl) ?Block {
        return child(n.syntax, Block);
    }
};

// ── 语句与控制流 ─────────────────────────────────────────────────────

pub const Label = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .label;

    pub fn name(n: Label) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }
};

pub const Block = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .block;

    pub fn label(n: Block) ?Label {
        return child(n.syntax, Label);
    }

    pub fn statements(n: Block) Nodes {
        return .{ .inner = n.syntax.children(), .skip = .label };
    }
};

/// `|x|`、`|*x, i|`：每个绑定是一个 identifier token
pub const Payload = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .payload;

    pub const Binding = struct { name: SyntaxToken, is_ptr: bool };

    pub fn bindings(n: Payload) Bindings {
        return .{ .inner = n.syntax.children() };
    }

    pub fn first(n: Payload) ?Binding {
        var it = n.bindings();
        return it.next();
    }

    pub const Bindings = struct {
        inner: SyntaxNode.Children,
        ptr: bool = false,

        pub fn next(it: *Bindings) ?Binding {
            while (it.inner.next()) |e| {
                if (e != .token) continue;
                switch (e.token.kind) {
                    .asterisk => it.ptr = true,
                    .identifier => {
                        defer it.ptr = false;
                        return .{ .name = e.token, .is_ptr = it.ptr };
                    },
                    else => {},
                }
            }
            return null;
        }
    };
};

pub const ElseClause = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .else_clause;

    pub fn payload(n: ElseClause) ?Payload {
        return child(n.syntax, Payload);
    }

    pub fn body(n: ElseClause) ?SyntaxNode {
        return firstNodeExcept(n.syntax, &.{.payload});
    }
};

pub const IfExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .if_expr;

    pub fn cond(n: IfExpr) ?SyntaxNode {
        return nodeAfter(n.syntax, .l_paren);
    }

    pub fn payload(n: IfExpr) ?Payload {
        return child(n.syntax, Payload);
    }

    pub fn then(n: IfExpr) ?SyntaxNode {
        return nodeAfterExcept(n.syntax, .r_paren, &.{ .payload, .else_clause });
    }

    pub fn @"else"(n: IfExpr) ?ElseClause {
        return child(n.syntax, ElseClause);
    }
};

pub const WhileExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .while_expr;

    pub fn label(n: WhileExpr) ?Label {
        return child(n.syntax, Label);
    }

    pub fn cond(n: WhileExpr) ?SyntaxNode {
        return nodeAfter(n.syntax, .l_paren);
    }

    pub fn payload(n: WhileExpr) ?Payload {
        return child(n.syntax, Payload);
    }

    /// `: (i += 1)` 中的表达式
    pub fn continueExpr(n: WhileExpr) ?SyntaxNode {
        const c = n.syntax.childNode(.while_continue) orelse return null;
        return nthNode(c, 0);
    }

    pub fn body(n: WhileExpr) ?SyntaxNode {
        return nodeAfterExcept(n.syntax, .r_paren, &.{ .payload, .while_continue, .else_clause });
    }

    pub fn @"else"(n: WhileExpr) ?ElseClause {
        return child(n.syntax, ElseClause);
    }

    pub fn isInline(n: WhileExpr) bool {
        return n.syntax.childToken(.keyword_inline) != null;
    }
};

pub const ForExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .for_expr;

    pub fn label(n: ForExpr) ?Label {
        return child(n.syntax, Label);
    }

    /// 每个输入是表达式，或 `a..b` 形式的 for_input 节点
    pub fn inputs(n: ForExpr) Nodes {
        const list = n.syntax.childNode(.for_inputs) orelse return .{ .inner = .{ .elems = &.{}, .offset = 0 } };
        return nodes(list);
    }

    pub fn payload(n: ForExpr) ?Payload {
        return child(n.syntax, Payload);
    }

    pub fn body(n: ForExpr) ?SyntaxNode {
        return firstNodeExcept(n.syntax, &.{ .label, .for_inputs, .payload, .else_clause });
    }

    pub fn @"else"(n: ForExpr) ?ElseClause {
        return child(n.syntax, ElseClause);
    }

    pub fn isInline(n: ForExpr) bool {
        return n.syntax.childToken(.keyword_inline) != null;
    }
};

pub const SwitchExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .switch_expr;

    pub fn label(n: SwitchExpr) ?Label {
        return child(n.syntax, Label);
    }

    pub fn operand(n: SwitchExpr) ?SyntaxNode {
        return nodeAfter(n.syntax, .l_paren);
    }

    pub fn prongs(n: SwitchExpr) Nodes {
        return .{ .inner = n.syntax.children(), .only = .switch_prong };
    }
};

pub const SwitchProng = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .switch_prong;

    /// `else` 分支没有分支项
    pub fn isElse(n: SwitchProng) bool {
        const case = n.syntax.childNode(.switch_case) orelse return false;
        return case.childToken(.keyword_else) != null;
    }

    /// 分支项：表达式，或 `a...b` 形式的 switch_item 节点
    pub fn items(n: SwitchProng) Nodes {
        const case = n.syntax.childNode(.switch_case) orelse return .{ .inner = .{ .elems = &.{}, .offset = 0 } };
        return nodes(case);
    }

    pub fn payload(n: SwitchProng) ?Payload {
        return child(n.syntax, Payload);
    }

    pub fn body(n: SwitchProng) ?SyntaxNode {
        return nodeAfterExcept(n.syntax, .equal_angle_bracket_right, &.{.payload});
    }
};

pub const AssignExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .assign_expr;

    pub fn lhs(n: AssignExpr) ?SyntaxNode {
        return nthNode(n.syntax, 0);
    }

    pub fn rhs(n: AssignExpr) ?SyntaxNode {
        return nthNode(n.syntax, 1);
    }
};

/// `a, var b = expr`：左侧是表达式或 var_decl（无初始化），最后一个子节点是右侧
pub const Destructure = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .destructure;

    pub fn targets(n: Destructure) Nodes {
        return nodes(n.syntax);
    }

    pub fn value(n: Destructure) ?SyntaxNode {
        return nodeAfter(n.syntax, .equal);
    }
};

pub const BreakExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .break_expr;

    pub fn label(n: BreakExpr) ?SyntaxToken {
        const l = n.syntax.childNode(.break_label) orelse return null;
        return l.childToken(.identifier);
    }

    pub fn value(n: BreakExpr) ?SyntaxNode {
        return firstNodeExcept(n.syntax, &.{.break_label});
    }
};

// ── 表达式 ───────────────────────────────────────────────────────────

pub const BinaryExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .binary_expr;

    pub fn lhs(n: BinaryExpr) ?SyntaxNode {
        return nthNode(n.syntax, 0);
    }

    /// 运算符 token
    pub fn op(n: BinaryExpr) ?SyntaxToken {
        var it = n.syntax.children();
        var seen_lhs = false;
        while (it.next()) |e| switch (e) {
            .node => seen_lhs = true,
            .token => |t| if (seen_lhs and !kind_mod.isTrivia(t.kind)) return t,
        };
        return null;
    }

    /// `catch |err|` 的捕获
    pub fn payload(n: BinaryExpr) ?Payload {
        return child(n.syntax, Payload);
    }

    pub fn rhs(n: BinaryExpr) ?SyntaxNode {
        var it = n.syntax.children();
        _ = it.nextNode();
        while (it.nextNode()) |c| if (c.kind() != .payload) return c;
        return null;
    }
};

pub const PrefixExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .prefix_expr;

    pub fn op(n: PrefixExpr) ?SyntaxToken {
        return n.syntax.firstToken();
    }

    pub fn operand(n: PrefixExpr) ?SyntaxNode {
        return nthNode(n.syntax, 0);
    }
};

pub const CallExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .call_expr;

    pub fn callee(n: CallExpr) ?SyntaxNode {
        return firstNodeExcept(n.syntax, &.{.arg_list});
    }

    pub fn args(n: CallExpr) Nodes {
        const list = n.syntax.childNode(.arg_list) orelse return .{ .inner = .{ .elems = &.{}, .offset = 0 } };
        return nodes(list);
    }
};

pub const BuiltinCall = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .builtin_call;

    /// 含 `@`，如 `@import`
    pub fn name(n: BuiltinCall) ?SyntaxToken {
        return n.syntax.childToken(.builtin);
    }

    pub fn args(n: BuiltinCall) Nodes {
        const list = n.syntax.childNode(.arg_list) orelse return .{ .inner = .{ .elems = &.{}, .offset = 0 } };
        return nodes(list);
    }
};

pub const FieldAccess = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .field_access;

    pub fn lhs(n: FieldAccess) ?SyntaxNode {
        return nthNode(n.syntax, 0);
    }

    /// `foo.` 尚未写完时为 null
    pub fn name(n: FieldAccess) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }

    pub fn dot(n: FieldAccess) ?SyntaxToken {
        return n.syntax.childToken(.period);
    }
};

pub const NameRef = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .name_ref;

    pub fn name(n: NameRef) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }
};

pub const EnumLiteral = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .enum_literal;

    pub fn name(n: EnumLiteral) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }
};

/// `T{ ... }` 或 `.{ ... }`
pub const InitExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .init_expr;

    /// `.{}` 没有类型
    pub fn typeExpr(n: InitExpr) ?SyntaxNode {
        return firstNodeExcept(n.syntax, &.{.init_list});
    }

    /// 每项是 field_init 或表达式
    pub fn items(n: InitExpr) Nodes {
        const list = n.syntax.childNode(.init_list) orelse return .{ .inner = .{ .elems = &.{}, .offset = 0 } };
        return nodes(list);
    }
};

pub const FieldInit = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .field_init;

    pub fn name(n: FieldInit) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }

    pub fn value(n: FieldInit) ?SyntaxNode {
        return nthNode(n.syntax, 0);
    }
};

pub const ErrorValue = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .error_value;

    pub fn name(n: ErrorValue) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }
};

/// 直接子节点（表达式按出现顺序）
pub fn childNodes(n: SyntaxNode) Nodes {
    return nodes(n);
}

const testing = std.testing;
const Parse = @import("Parse.zig");

fn parseFirst(gpa: std.mem.Allocator, text: []const u8) !*Parse {
    return Parse.create(gpa, text);
}

test "declarations and fn proto" {
    const p = try parseFirst(testing.allocator,
        \\pub fn add(comptime T: type, a: T, b: anytype) !T { return a; }
        \\const x: u32 align(4) = 1;
        \\const S = struct { a: u8 = 1, u16, };
    );
    defer p.destroy();
    var members = nodes(p.rootNode());
    const f = cast(FnDecl, members.next().?).?;
    const proto = f.proto().?;
    try testing.expectEqualStrings("add", proto.name().?.text);
    var params = proto.params();
    const p0 = cast(Param, params.next().?).?;
    try testing.expect(p0.isComptime());
    try testing.expectEqualStrings("T", p0.name().?.text);
    _ = params.next();
    const p2 = cast(Param, params.next().?).?;
    try testing.expect(p2.typeExpr() == null);
    try testing.expect(params.next() == null);
    try testing.expectEqual(.name_ref, proto.returnType().?.kind());
    try testing.expect(proto.inferredErrorSet());
    try testing.expect(f.body() != null);

    const v = cast(VarDecl, members.next().?).?;
    try testing.expectEqualStrings("x", v.name().?.text);
    try testing.expectEqual(.name_ref, v.typeExpr().?.kind());
    try testing.expectEqual(.literal, v.initExpr().?.kind());

    const s = cast(VarDecl, members.next().?).?;
    const c = cast(ContainerDecl, s.initExpr().?).?;
    try testing.expectEqual(.@"struct", c.keyword().?);
    var fields = nodes(c.syntax);
    const a = cast(ContainerField, fields.next().?).?;
    try testing.expectEqualStrings("a", a.name().?.text);
    try testing.expectEqual(.literal, a.defaultValue().?.kind());
    const tuple = cast(ContainerField, fields.next().?).?;
    try testing.expect(tuple.name() == null);
    try testing.expectEqual(.name_ref, tuple.typeExpr().?.kind());
}

test "control flow" {
    const p = try parseFirst(testing.allocator,
        \\fn f() void {
        \\    if (a) |x| b else |e| c;
        \\    blk: while (i < n) : (i += 1) { } else {}
        \\    for (xs, 0..) |*x, i| {}
        \\    switch (v) { 1, 2 => |p| q, else => r }
        \\    const y = a catch |err| b;
        \\    foo.
        \\}
    );
    defer p.destroy();
    var members = nodes(p.rootNode());
    const body = cast(FnDecl, members.next().?).?.body().?;
    var stmts = body.statements();

    const if_e = cast(IfExpr, stmts.next().?).?;
    try testing.expectEqual(.name_ref, if_e.cond().?.kind());
    var b = if_e.payload().?.bindings();
    try testing.expectEqualStrings("x", b.next().?.name.text);
    try testing.expectEqualStrings("b", if_e.then().?.text(p.source));
    try testing.expectEqualStrings("e", if_e.@"else"().?.payload().?.first().?.name.text);
    // 语句形式的 else 分支是带分号的 expr_stmt
    try testing.expectEqualStrings("c;", if_e.@"else"().?.body().?.text(p.source));

    const w = cast(WhileExpr, stmts.next().?).?;
    try testing.expectEqualStrings("blk", w.label().?.name().?.text);
    try testing.expectEqual(.binary_expr, w.cond().?.kind());
    try testing.expectEqual(.assign_expr, w.continueExpr().?.kind());
    try testing.expectEqual(.block, w.body().?.kind());
    try testing.expect(w.@"else"() != null);

    const fe = cast(ForExpr, stmts.next().?).?;
    var inputs = fe.inputs();
    try testing.expectEqual(.name_ref, inputs.next().?.kind());
    try testing.expectEqual(.for_input, inputs.next().?.kind());
    var fb = fe.payload().?.bindings();
    try testing.expect(fb.next().?.is_ptr);
    try testing.expect(!fb.next().?.is_ptr);
    try testing.expectEqual(.block, fe.body().?.kind());

    const sw = cast(SwitchExpr, stmts.next().?).?;
    try testing.expectEqualStrings("v", sw.operand().?.text(p.source));
    var prongs = sw.prongs();
    const p0 = cast(SwitchProng, prongs.next().?).?;
    var items = p0.items();
    _ = items.next();
    _ = items.next();
    try testing.expect(items.next() == null);
    try testing.expectEqualStrings("q", p0.body().?.text(p.source));
    try testing.expect(cast(SwitchProng, prongs.next().?).?.isElse());

    const decl = cast(VarDecl, stmts.next().?).?;
    const catch_e = cast(BinaryExpr, decl.initExpr().?).?;
    try testing.expectEqual(.keyword_catch, catch_e.op().?.kind);
    try testing.expectEqualStrings("err", catch_e.payload().?.first().?.name.text);
    try testing.expectEqualStrings("b", catch_e.rhs().?.text(p.source));

    // `foo.`：字段名缺失
    const stmt = stmts.next().?;
    const fa = cast(FieldAccess, stmt.childNode(.field_access).?).?;
    try testing.expect(fa.name() == null);
    try testing.expect(fa.dot() != null);
}
