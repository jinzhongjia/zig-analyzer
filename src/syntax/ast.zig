//! Typed AST access layer: semantic access to substructures on top of the CST.
//!
//! The knowledge of "which child node holds which information" is centralized here; callers
//! write `decl.proto().?.name()` instead of counting child nodes, and when the syntax tree
//! structure changes, only this place changes. All accessors return optionals: any part of an
//! error-tolerant parse tree may be missing. Expressions are not distinguished by kind; they all
//! use `SyntaxNode`, and users dispatch on `kind()`.

const std = @import("std");
const tree = @import("tree.zig");
const kind_mod = @import("kind.zig");
pub const SyntaxNode = tree.SyntaxNode;
pub const SyntaxToken = tree.SyntaxToken;
pub const SyntaxKind = kind_mod.SyntaxKind;

/// Converts to `T` when the node is of `T`'s kind
pub fn cast(comptime T: type, n: SyntaxNode) ?T {
    return if (n.kind() == T.kind) .{ .syntax = n } else null;
}

/// The first direct child node of kind `T`
fn child(n: SyntaxNode, comptime T: type) ?T {
    return if (n.childNode(T.kind)) |c| .{ .syntax = c } else null;
}

/// The `index`-th direct child node
fn nthNode(n: SyntaxNode, index: usize) ?SyntaxNode {
    var it = n.children();
    var i: usize = 0;
    while (it.nextNode()) |c| : (i += 1) if (i == index) return c;
    return null;
}

/// The first direct child node that appears after `token`
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

/// The first direct child node whose kind is not in `skip`
fn firstNodeExcept(n: SyntaxNode, skip: []const SyntaxKind) ?SyntaxNode {
    var it = n.children();
    while (it.nextNode()) |c| {
        if (std.mem.indexOfScalar(SyntaxKind, skip, c.kind()) == null) return c;
    }
    return null;
}

/// The first direct child node after `token` whose kind is not in `skip`
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

/// The first direct child node after `open`, or null when a token in `closers` comes before it
/// (the slot between them is empty)
fn nodeInSlot(n: SyntaxNode, open: SyntaxKind, closers: []const SyntaxKind) ?SyntaxNode {
    var it = n.children();
    var seen = false;
    while (it.next()) |e| switch (e) {
        .token => |t| if (t.kind == open) {
            seen = true;
        } else if (seen and std.mem.indexOfScalar(SyntaxKind, closers, t.kind) != null) return null,
        .node => |c| if (seen) return c,
    };
    return null;
}

/// Iterator over direct child nodes (optionally filtered by kind)
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

// ── Containers and declarations ──────────────────────────────────────

/// Container members: fn_decl, var_decl, container_field, test_decl, comptime_decl
pub fn isMember(k: SyntaxKind) bool {
    return switch (k) {
        .fn_decl, .var_decl, .container_field, .test_decl, .comptime_decl => true,
        else => false,
    };
}

/// Name of an identifier: the quotes of the `@"name"` form are removed (names with escapes keep
/// the source text; see `identNameAlloc` for decoding).
/// The semantic layers (name resolution, fields, enum members) always use the unquoted, decoded
/// name, adding the quotes back for display when needed (`std.zig.fmtId`)
pub fn identName(text: []const u8) []const u8 {
    if (isQuotedIdent(text)) {
        const inner = text[2 .. text.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    }
    return text;
}

fn isQuotedIdent(text: []const u8) bool {
    return text.len >= 3 and text[0] == '@' and text[1] == '"' and text[text.len - 1] == '"';
}

/// Like `identName`, but decodes escapes (`@"\x66oo"` is `foo`). Without escapes the result
/// references the source text; with invalid escapes the source text is kept as is
pub fn identNameAlloc(a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    const name = identName(text);
    if (name.ptr != text.ptr or !isQuotedIdent(text)) return name;
    return std.zig.string_literal.parseAlloc(a, text[1..]) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidLiteral => text,
    };
}

/// Name token of a container member: function, variable, field, or test name (a string or an
/// identifier); null when there is no name.
/// Enum members and void fields of unions may lack the colon, with the name where the type
/// expression goes; the caller has to indicate this (`in_enum`)
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

    /// The integer type of `enum(u8)`, the tag type of `union(E)`
    /// The expression inside the parentheses of `enum(u8)` / `union(E)` / `packed struct(u32)`.
    /// `union(enum)` has no expression inside the parentheses; must not reach past `)` and take
    /// the first member
    pub fn argExpr(n: ContainerDecl) ?SyntaxNode {
        var it = n.syntax.children();
        var depth: u32 = 0;
        while (it.next()) |e| switch (e) {
            .token => |t| switch (t.kind) {
                .l_paren => depth += 1,
                .r_paren => if (depth <= 1) return null else {
                    depth -= 1;
                },
                .l_brace => return null,
                else => {},
            },
            .node => |c| if (depth > 0) return c,
        };
        return null;
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

    /// `!T`: the return type has an inferred error set
    pub fn inferredErrorSet(n: FnProto) bool {
        return n.syntax.childToken(.bang) != null;
    }

    /// Expressions in the clauses (align / addrspace / linksection / callconv)
    pub fn clauses(n: FnProto) [4]?SyntaxNode {
        var out: [4]?SyntaxNode = @splat(null);
        for ([_]SyntaxKind{ .align_clause, .addrspace_clause, .linksection_clause, .callconv_clause }, &out) |k, *o| {
            if (n.syntax.childNode(k)) |c| o.* = c;
        }
        return out;
    }

    /// Display of the signature: `fn name(a: T, b: U) callconv(.c) R`, made up of `writeParams`
    /// and `writeReturnType`; a function type without a name is `fn (a: T) R`, as `zig fmt`
    /// writes it
    pub fn writeSignature(n: FnProto, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("fn");
        if (n.name()) |t| try w.print(" {s}", .{t.text}) else try w.writeByte(' ');
        try n.writeParams(w);
        if (n.returnType() == null) return;
        try w.writeByte(' ');
        try n.writeReturnType(w);
    }

    /// Byte range of each parameter (as written by `writeCollapsed`) in the text of
    /// `writeSignature`, in the order of `params`; follows the layout of `writeSignature` and
    /// `writeParams`
    pub fn signatureParamRanges(n: FnProto, a: std.mem.Allocator) std.mem.Allocator.Error![]const [2]u32 {
        var out: std.ArrayList([2]u32) = .empty;
        // `fn name(` or `fn (`
        var at: usize = "fn ".len + (if (n.name()) |t| t.text.len else 0) + "(".len;
        var it = n.params();
        var first = true;
        while (it.next()) |p| : (first = false) {
            if (!first) at += ", ".len;
            var counter: std.Io.Writer.Discarding = .init(&.{});
            writeCollapsed(p, &counter.writer) catch unreachable;
            const end = at + counter.fullCount();
            try out.append(a, .{ @intCast(at), @intCast(end) });
            at = end;
        }
        return out.items;
    }

    /// Parameter list and the clauses after it: `(a: T, b: U) callconv(.c)`. For each part see
    /// `writeCollapsed`; parameters are separated by `, `
    /// (the trailing comma of a multiline parameter list is not shown)
    pub fn writeParams(n: FnProto, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('(');
        var it = n.params();
        var first = true;
        while (it.next()) |p| : (first = false) {
            if (!first) try w.writeAll(", ");
            try writeCollapsed(p, w);
        }
        try w.writeByte(')');
        var children = n.syntax.children();
        while (children.nextNode()) |c| switch (c.kind()) {
            .align_clause, .addrspace_clause, .linksection_clause, .callconv_clause => {
                try w.writeByte(' ');
                try writeCollapsed(c, w);
            },
            else => {},
        };
    }

    /// Return type (with `!` for an inferred error set), see `writeCollapsed`;
    /// writes nothing when missing
    pub fn writeReturnType(n: FnProto, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const ret = n.returnType() orelse return;
        if (n.inferredErrorSet()) try w.writeByte('!');
        try writeCollapsed(ret, w);
    }
};

pub const Param = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .param;

    pub fn name(n: Param) ?SyntaxToken {
        return n.syntax.childToken(.identifier);
    }

    /// `anytype` and `...` have no type expression
    pub fn typeExpr(n: Param) ?SyntaxNode {
        return nthNode(n.syntax, 0);
    }

    pub fn isComptime(n: Param) bool {
        return n.syntax.childToken(.keyword_comptime) != null;
    }

    /// The C-variadic `...`, which takes every remaining argument
    pub fn isVarargs(n: Param) bool {
        return n.syntax.childToken(.ellipsis3) != null;
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

    /// Null when the type after `:` is missing (the clauses and the initializer that follow are
    /// not the type)
    pub fn typeExpr(n: VarDecl) ?SyntaxNode {
        const t = nodeInSlot(n.syntax, .colon, &.{ .equal, .equal_equal, .semicolon }) orelse return null;
        return switch (t.kind()) {
            .align_clause, .addrspace_clause, .linksection_clause => null,
            else => t,
        };
    }

    pub fn initExpr(n: VarDecl) ?SyntaxNode {
        return nodeAfter(n.syntax, .equal) orelse nodeAfter(n.syntax, .equal_equal);
    }
};

pub const ContainerField = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .container_field;

    /// Tuple fields have no name
    pub fn name(n: ContainerField) ?SyntaxToken {
        if (n.syntax.childToken(.colon) == null) return null;
        return n.syntax.childToken(.identifier);
    }

    /// Null when the type is missing (`a: = 1`): the align clause and the default value are not it
    pub fn typeExpr(n: ContainerField) ?SyntaxNode {
        var it = n.syntax.children();
        while (it.next()) |e| switch (e) {
            .token => |t| if (t.kind == .equal) return null,
            .node => |c| return if (c.kind() == .align_clause) null else c,
        };
        return null;
    }

    /// Enum member `red` / `red = 1`: the name is in the position of the type expression
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

// ── Statements and control flow ──────────────────────────────────────

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

/// `|x|`, `|*x, i|`: each binding is an identifier token
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
        return nodeInSlot(n.syntax, .l_paren, &.{.r_paren});
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
        return nodeInSlot(n.syntax, .l_paren, &.{.r_paren});
    }

    pub fn payload(n: WhileExpr) ?Payload {
        return child(n.syntax, Payload);
    }

    /// The expression in `: (i += 1)`
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

    /// Each input is an expression, or a for_input node of the form `a..b`
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
        return nodeInSlot(n.syntax, .l_paren, &.{.r_paren});
    }

    pub fn prongs(n: SwitchExpr) Nodes {
        return .{ .inner = n.syntax.children(), .only = .switch_prong };
    }
};

pub const SwitchProng = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .switch_prong;

    pub fn isInline(n: SwitchProng) bool {
        return n.syntax.childToken(.keyword_inline) != null;
    }

    /// The `else` prong has no items
    pub fn isElse(n: SwitchProng) bool {
        const case = n.syntax.childNode(.switch_case) orelse return false;
        return case.childToken(.keyword_else) != null;
    }

    /// Prong items: expressions, or switch_item nodes of the form `a...b`
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

/// `a, var b = expr`: the left side holds expressions or var_decls (without initializers);
/// the last child node is the right side
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

// ── Expressions ──────────────────────────────────────────────────────

pub const BinaryExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .binary_expr;

    pub fn lhs(n: BinaryExpr) ?SyntaxNode {
        return nthNode(n.syntax, 0);
    }

    /// Operator token
    pub fn op(n: BinaryExpr) ?SyntaxToken {
        var it = n.syntax.children();
        var seen_lhs = false;
        while (it.next()) |e| switch (e) {
            .node => seen_lhs = true,
            .token => |t| if (seen_lhs and !kind_mod.isTrivia(t.kind)) return t,
        };
        return null;
    }

    /// The capture of `catch |err|`
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

    /// Includes the `@`, e.g. `@import`
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

    /// null while `foo.` is not yet complete
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

/// `T{ ... }` or `.{ ... }`
pub const InitExpr = struct {
    syntax: SyntaxNode,
    pub const kind: SyntaxKind = .init_expr;

    /// `.{}` has no type
    pub fn typeExpr(n: InitExpr) ?SyntaxNode {
        return firstNodeExcept(n.syntax, &.{.init_list});
    }

    /// Each item is a field_init or an expression
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

/// Direct child nodes (expressions in order of appearance)
pub fn childNodes(n: SyntaxNode) Nodes {
    return nodes(n);
}

/// Display text of a node (parts of a signature): the source with comments and doc comments
/// removed, and whitespace and comments between tokens collapsed into a single space
pub fn writeCollapsed(n: SyntaxNode, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var c: Collapser = .{ .w = w };
    try c.walk(n);
}

pub fn collapsedAlloc(a: std.mem.Allocator, n: SyntaxNode) std.mem.Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    writeCollapsed(n, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

const Collapser = struct {
    w: *std.Io.Writer,
    started: bool = false,
    space: bool = false,

    fn walk(c: *Collapser, n: SyntaxNode) std.Io.Writer.Error!void {
        var it = n.children();
        while (it.next()) |e| switch (e) {
            .node => |inner| try c.walk(inner),
            .token => |t| if (kind_mod.isTrivia(t.kind) or t.kind == .doc_comment) {
                c.space = c.started;
            } else {
                if (c.space) try c.w.writeByte(' ');
                try c.w.writeAll(t.text);
                c.started = true;
                c.space = false;
            },
        };
    }
};

const testing = std.testing;
const Parse = @import("Parse.zig");

fn parseFirst(gpa: std.mem.Allocator, text: []const u8) !*Parse {
    return Parse.create(gpa, text, .zig);
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

test "fn signature display drops comments and collapses whitespace" {
    const p = try parseFirst(testing.allocator,
        \\fn lazy(
        \\    /// The build struct
        \\    b: *Build, // the builder
        \\    comptime T: type,
        \\    x:anytype,
        \\) align(4) callconv(.c) error{ A,
        \\    B }!?[]const u8 {}
        \\fn g(fmt: [*:0]const u8, ...) !void {}
        \\fn h() E!T {}
        \\fn s(m: []const u8) @TypeOf("a  b") {}
        \\fn missing(a: u32)
    );
    defer p.destroy();
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "fn lazy(b: *Build, comptime T: type, x:anytype) align(4) callconv(.c) error{ A, B }!?[]const u8", "(b: *Build, comptime T: type, x:anytype) align(4) callconv(.c)", "error{ A, B }!?[]const u8" },
        .{ "fn g(fmt: [*:0]const u8, ...) !void", "(fmt: [*:0]const u8, ...)", "!void" },
        .{ "fn h() E!T", "()", "E!T" },
        // Whitespace inside strings is kept as is
        .{ "fn s(m: []const u8) @TypeOf(\"a  b\")", "(m: []const u8)", "@TypeOf(\"a  b\")" },
        .{ "fn missing(a: u32)", "(a: u32)", "" },
    };
    var members = nodes(p.rootNode());
    for (cases) |c| {
        const proto = cast(FnDecl, members.next().?).?.proto().?;
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try proto.writeSignature(&out.writer);
        try testing.expectEqualStrings(c[0], out.written());
        // Each parameter range covers that parameter in the signature
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var params = proto.params();
        for (try proto.signatureParamRanges(arena.allocator())) |range| {
            try testing.expectEqualStrings(try collapsedAlloc(arena.allocator(), params.next().?), out.written()[range[0]..range[1]]);
        }
        try testing.expect(params.next() == null);
        out.clearRetainingCapacity();
        try proto.writeParams(&out.writer);
        try testing.expectEqualStrings(c[1], out.written());
        out.clearRetainingCapacity();
        try proto.writeReturnType(&out.writer);
        try testing.expectEqualStrings(c[2], out.written());
    }
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
    // The else branch in statement form is an expr_stmt with a semicolon
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

    // `foo.`: the field name is missing
    const stmt = stmts.next().?;
    const fa = cast(FieldAccess, stmt.childNode(.field_access).?).?;
    try testing.expect(fa.name() == null);
    try testing.expect(fa.dot() != null);
}

test "a missing type, condition or operand is null, not the next node" {
    const p = try parseFirst(testing.allocator,
        \\const x: = 5;
        \\var y: align(4) = 5;
        \\const S = struct { a: = 5, b: align(4) = 6 };
        \\fn f() void {
        \\    if () {}
        \\    while () {}
        \\    switch () { .a => |v| v }
        \\}
    );
    defer p.destroy();
    var members = nodes(p.rootNode());
    const x = cast(VarDecl, members.next().?).?;
    try testing.expect(x.typeExpr() == null);
    try testing.expectEqual(.literal, x.initExpr().?.kind());
    const y = cast(VarDecl, members.next().?).?;
    try testing.expect(y.typeExpr() == null);
    const s = cast(ContainerDecl, cast(VarDecl, members.next().?).?.initExpr().?).?;
    var fields = nodes(s.syntax);
    const a = cast(ContainerField, fields.next().?).?;
    try testing.expect(a.typeExpr() == null);
    try testing.expectEqual(.literal, a.defaultValue().?.kind());
    try testing.expect(cast(ContainerField, fields.next().?).?.typeExpr() == null);
    var stmts = cast(FnDecl, members.next().?).?.body().?.statements();
    try testing.expect(cast(IfExpr, stmts.next().?).?.cond() == null);
    try testing.expect(cast(WhileExpr, stmts.next().?).?.cond() == null);
    try testing.expect(cast(SwitchExpr, stmts.next().?).?.operand() == null);
}
