//! CST → HIR lowering, which also computes local scopes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../syntax/ast.zig");
const SyntaxNode = ast.SyntaxNode;
const SyntaxToken = ast.SyntaxToken;
const SyntaxKind = ast.SyntaxKind;
const isTrivia = @import("../syntax/kind.zig").isTrivia;
const Body = @import("Body.zig");
const ExprId = Body.ExprId;
const BindingId = Body.BindingId;
const ScopeId = Body.ScopeId;
const Expr = Body.Expr;
const Range = Body.Range;

const Error = Allocator.Error;

/// What is being lowered
pub const Owner = enum {
    /// A container member (fn_decl / var_decl / container_field / test_decl / comptime_decl)
    member,
    /// An enum member or a union field written as just a name (`red`, `red = 1`,
    /// `union(enum) { b }`): the type expression position holds its name, not an expression
    bare_field,
    /// The root expression of a ZON file: `inf` and `nan` are float literals
    zon,
};

/// Lowers `member`: a container member, or the root expression of a ZON file (`owner == .zon`)
pub fn lower(gpa: Allocator, member: SyntaxNode, owner: Owner) Error!Body {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var l: Lowerer = .{ .gpa = gpa, .a = arena.allocator(), .base = member.offset, .zon = owner == .zon };
    defer l.deinit();
    try l.scopes.append(gpa, .{ .parent = null, .bindings = &.{} });

    var value: ?ExprId = null;
    var type_expr: ?ExprId = null;
    var align_expr: ?ExprId = null;
    var params: std.ArrayList(BindingId) = .empty;
    if (owner == .zon) value = try l.expr(member) else switch (member.kind()) {
        .fn_decl => {
            const decl = ast.cast(ast.FnDecl, member).?;
            if (decl.proto()) |proto| {
                // The type of each parameter is evaluated in the scope of the preceding
                // parameters: `fn f(comptime T: type, x: T)`
                var it = proto.params();
                while (it.next()) |p| {
                    const param = ast.cast(ast.Param, p).?;
                    const ty = try l.optExpr(param.typeExpr());
                    // An unnamed parameter (`fn f(*const u32) void` of an extern function) is
                    // bound with an empty name so that parameters still correspond by position;
                    // `...` is not bound
                    const name = param.name() orelse if (ty != null) SyntaxToken{ .kind = .identifier, .text = "", .offset = p.offset } else continue;
                    const b = try l.bind(name, .param, .{ .ty = ty, .is_comptime = param.isComptime() });
                    try params.append(l.a, b);
                    _ = try l.pushScope(&.{b});
                }
                for (proto.clauses()) |c| if (c) |n| {
                    _ = try l.clause(n);
                };
                type_expr = try l.optExpr(proto.returnType());
            }
            if (decl.body()) |b| value = try l.expr(b.syntax);
        },
        .var_decl => {
            const decl = ast.cast(ast.VarDecl, member).?;
            type_expr = try l.optExpr(decl.typeExpr());
            align_expr = try l.clauses(member);
            value = try l.optExpr(decl.initExpr());
        },
        .container_field => {
            const field = ast.cast(ast.ContainerField, member).?;
            type_expr = if (owner == .bare_field) null else try l.optExpr(field.typeExpr());
            align_expr = try l.clauses(member);
            value = try l.optExpr(field.defaultValue());
        },
        .test_decl => if (ast.cast(ast.TestDecl, member).?.body()) |b| {
            value = try l.expr(b.syntax);
        },
        .comptime_decl => if (ast.cast(ast.ComptimeDecl, member).?.body()) |b| {
            value = try l.expr(b.syntax);
        },
        else => {},
    }

    var body: Body = .{
        .arena = undefined,
        .exprs = try l.a.dupe(Expr, l.exprs.items),
        .expr_ranges = try l.a.dupe(Range, l.ranges.items),
        .expr_scopes = try l.a.dupe(ScopeId, l.expr_scopes.items),
        .bindings = try l.a.dupe(Body.Binding, l.bindings.items),
        .scopes = try l.a.dupe(Body.Scope, l.scopes.items),
        .params = params.items,
        .value = value,
        .type_expr = type_expr,
        .align_expr = align_expr,
        .clauses = l.clause_list.items,
    };
    body.arena = arena.state;
    return body;
}

const Lowerer = struct {
    gpa: Allocator,
    /// Arena of the Body: names and the various slices
    a: Allocator,
    /// Start of the owner node
    base: u32,
    /// A ZON file: `inf` and `nan` are float literals, not names
    zon: bool,
    exprs: std.ArrayList(Expr) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    expr_scopes: std.ArrayList(ScopeId) = .empty,
    bindings: std.ArrayList(Body.Binding) = .empty,
    scopes: std.ArrayList(Body.Scope) = .empty,
    /// Allocated in the arena of the Body
    clause_list: std.ArrayList(Body.Clause) = .empty,
    scope: ScopeId = .root,

    fn deinit(l: *Lowerer) void {
        l.exprs.deinit(l.gpa);
        l.ranges.deinit(l.gpa);
        l.expr_scopes.deinit(l.gpa);
        l.bindings.deinit(l.gpa);
        l.scopes.deinit(l.gpa);
    }

    fn rel(l: *Lowerer, start: u32, end: u32) Range {
        return .{ .start = start - l.base, .end = end - l.base };
    }

    fn nodeRange(l: *Lowerer, n: SyntaxNode) Range {
        const r = n.range();
        return l.rel(r.start, r.end);
    }

    fn add(l: *Lowerer, e: Expr, r: Range) Error!ExprId {
        const id: ExprId = @fromBackingInt(@as(u32, @intCast(l.exprs.items.len)));
        try l.exprs.append(l.gpa, e);
        try l.ranges.append(l.gpa, r);
        try l.expr_scopes.append(l.gpa, l.scope);
        return id;
    }

    fn str(l: *Lowerer, s: []const u8) Error![]const u8 {
        return l.a.dupe(u8, s);
    }

    /// Source text of a literal; for a multiline string literal, the tokens of its lines joined
    /// with newlines (see `Body.Expr.literal`)
    fn literal(l: *Lowerer, n: SyntaxNode) Error![]const u8 {
        const first = n.firstToken() orelse return "";
        if (first.kind != .multiline_string_literal_line) return l.str(first.text);
        var text: std.ArrayList(u8) = .empty;
        var it = n.children();
        while (it.next()) |c| switch (c) {
            .token => |t| if (t.kind == .multiline_string_literal_line) {
                if (text.items.len > 0) try text.append(l.a, '\n');
                try text.appendSlice(l.a, t.text);
            },
            .node => {},
        };
        return text.items;
    }

    /// Text of a token; for a `@"name"` identifier, the decoded name without the quotes
    fn tokenText(l: *Lowerer, t: ?SyntaxToken) Error!?[]const u8 {
        return if (t) |tok| try l.ident(tok.text) else null;
    }

    fn ident(l: *Lowerer, text: []const u8) Error![]const u8 {
        return l.str(try ast.identNameAlloc(l.a, text));
    }

    /// Creates a child scope of the current scope and enters it
    fn pushScope(l: *Lowerer, bindings: []const BindingId) Error!ScopeId {
        return l.pushScopeLabeled(bindings, null);
    }

    fn pushScopeLabeled(l: *Lowerer, bindings: []const BindingId, label: @FieldType(Body.Scope, "label")) Error!ScopeId {
        const id: ScopeId = @fromBackingInt(@as(u32, @intCast(l.scopes.items.len)));
        try l.scopes.append(l.gpa, .{ .parent = l.scope, .bindings = try l.a.dupe(BindingId, bindings), .label = label });
        l.scope = id;
        return id;
    }

    fn bind(l: *Lowerer, name: SyntaxToken, kind: Body.Binding.Kind, extra: struct { ty: ?ExprId = null, init: ?ExprId = null, is_ptr: bool = false, is_comptime: bool = false }) Error!BindingId {
        const id: BindingId = @fromBackingInt(@as(u32, @intCast(l.bindings.items.len)));
        const r = name.range();
        try l.bindings.append(l.gpa, .{
            .name = try l.ident(name.text),
            .kind = kind,
            .range = l.rel(r.start, r.end),
            .ty = extra.ty,
            .init = extra.init,
            .is_ptr = extra.is_ptr,
            .is_comptime = extra.is_comptime,
        });
        return id;
    }

    /// Bindings of a capture `|a, *b|`
    fn captures(l: *Lowerer, payload: ?ast.Payload) Error![]const BindingId {
        const p = payload orelse return &.{};
        var out: std.ArrayList(BindingId) = .empty;
        var it = p.bindings();
        while (it.next()) |b| try out.append(l.a, try l.bind(b.name, .capture, .{ .is_ptr = b.is_ptr }));
        return out.items;
    }

    fn optExpr(l: *Lowerer, n: ?SyntaxNode) Error!?ExprId {
        return if (n) |node| try l.expr(node) else null;
    }

    fn exprOrMissing(l: *Lowerer, n: ?SyntaxNode) Error!ExprId {
        return if (n) |node| try l.expr(node) else try l.add(.missing, .none);
    }

    fn exprList(l: *Lowerer, it: ast.Nodes) Error![]const ExprId {
        var nodes = it;
        var out: std.ArrayList(ExprId) = .empty;
        while (nodes.next()) |n| try out.append(l.a, try l.expr(n));
        return out.items;
    }

    /// Expressions in align / addrspace / linksection / callconv clauses; returns the expression in
    /// the align clause
    fn clauses(l: *Lowerer, n: SyntaxNode) Error!?ExprId {
        var align_expr: ?ExprId = null;
        var it = n.children();
        while (it.nextNode()) |c| switch (c.kind()) {
            .align_clause, .addrspace_clause, .linksection_clause, .callconv_clause => {
                const e = try l.clause(c);
                if (c.kind() == .align_clause) align_expr = e;
            },
            else => {},
        };
        return align_expr;
    }

    /// One clause: the clause itself is lowered to `.other` and its expressions are recorded in
    /// `clauses`; returns the first of them
    fn clause(l: *Lowerer, c: SyntaxNode) Error!?ExprId {
        const id = try l.expr(c);
        const children = switch (l.exprs.items[@backingInt(id)]) {
            .other => |children| children,
            else => return null,
        };
        const kind: Body.Clause.Kind = switch (c.kind()) {
            .align_clause => .@"align",
            .addrspace_clause => .@"addrspace",
            .linksection_clause => .@"linksection",
            .callconv_clause => .@"callconv",
            else => unreachable,
        };
        for (children, 0..) |x, i| try l.clause_list.append(l.a, .{ .kind = if (i == 0) kind else .bit_range, .expr = x });
        return if (children.len == 1) children[0] else null;
    }

    fn expr(l: *Lowerer, n: SyntaxNode) Error!ExprId {
        const r = l.nodeRange(n);
        const e: Expr = switch (n.kind()) {
            // Parentheses and branches in statement form do not get a node of their own
            .paren_expr, .expr_stmt => return l.exprOrMissing(firstChild(n)),
            // A recovered reference position may hold only an invalid token; a missing name stays
            // unknown and does not enter name resolution.
            .name_ref => if ((ast.NameRef{ .syntax = n }).name()) |name|
                if (l.zon and Body.zonFloatValue(name.text) != null) .{ .literal = try l.str(name.text) } else .{ .name_ref = try l.ident(name.text) }
            else
                .missing,
            .literal => .{ .literal = try l.literal(n) },
            .field_access => blk: {
                const fa = ast.FieldAccess{ .syntax = n };
                break :blk .{ .field_access = .{ .lhs = try l.exprOrMissing(fa.lhs()), .field = try l.tokenText(fa.name()) } };
            },
            .enum_literal => .{ .enum_literal = try l.tokenText((ast.EnumLiteral{ .syntax = n }).name()) orelse "" },
            .error_value => .{ .error_value = try l.tokenText((ast.ErrorValue{ .syntax = n }).name()) orelse "" },
            .builtin_call => blk: {
                const b = ast.BuiltinCall{ .syntax = n };
                break :blk .{ .builtin_call = .{ .name = try l.tokenText(b.name()) orelse "@", .args = try l.exprList(b.args()) } };
            },
            .call_expr => blk: {
                const c = ast.CallExpr{ .syntax = n };
                break :blk .{ .call = .{ .callee = try l.exprOrMissing(c.callee()), .args = try l.exprList(c.args()) } };
            },
            .block => return l.block(n),
            .if_expr => return l.ifExpr(n),
            .while_expr, .for_expr => return l.loop(n),
            .switch_expr => return l.switchExpr(n),
            .binary_expr => blk: {
                const b = ast.BinaryExpr{ .syntax = n };
                const op = if (b.op()) |t| t.kind else .invalid;
                const lhs = try l.exprOrMissing(b.lhs());
                if (op == .keyword_catch) {
                    const saved = l.scope;
                    defer l.scope = saved;
                    const caps = try l.captures(b.payload());
                    if (caps.len != 0) _ = try l.pushScope(caps);
                    const rhs = try l.exprOrMissing(b.rhs());
                    l.scope = saved;
                    break :blk .{ .@"catch" = .{ .lhs = lhs, .capture = if (caps.len != 0) caps[0] else null, .rhs = rhs } };
                }
                break :blk .{ .binary = .{ .op = op, .lhs = lhs, .rhs = try l.exprOrMissing(b.rhs()) } };
            },
            .prefix_expr => blk: {
                const p = ast.PrefixExpr{ .syntax = n };
                break :blk .{ .prefix = .{ .op = if (p.op()) |t| t.kind else .invalid, .operand = try l.exprOrMissing(p.operand()) } };
            },
            .assign_expr => blk: {
                const a = ast.AssignExpr{ .syntax = n };
                break :blk .{ .assign = .{ .op = opAfterFirstNode(n), .lhs = try l.exprOrMissing(a.lhs()), .rhs = try l.exprOrMissing(a.rhs()) } };
            },
            .index_expr => blk: {
                var it = ast.childNodes(n);
                break :blk .{ .index = .{ .lhs = try l.exprOrMissing(it.next()), .index = try l.exprOrMissing(it.next()) } };
            },
            .slice_expr => blk: {
                var it = ast.childNodes(n);
                const lhs = try l.exprOrMissing(it.next());
                const start = try l.exprOrMissing(it.next());
                var end: ?ExprId = null;
                var sentinel: ?ExprId = null;
                while (it.next()) |c| {
                    if (c.kind() == .sentinel) sentinel = try l.exprOrMissing(firstChild(c)) else end = try l.expr(c);
                }
                break :blk .{ .slice = .{ .lhs = lhs, .start = start, .end = end, .sentinel = sentinel } };
            },
            .deref_expr => .{ .deref = try l.exprOrMissing(firstChild(n)) },
            .unwrap_optional => .{ .unwrap_optional = try l.exprOrMissing(firstChild(n)) },
            .init_expr => blk: {
                const i = ast.InitExpr{ .syntax = n };
                const ty = try l.optExpr(i.typeExpr());
                var fields: std.ArrayList(Body.FieldInit) = .empty;
                var it = i.items();
                while (it.next()) |item| {
                    if (ast.cast(ast.FieldInit, item)) |f| {
                        const name_range: Range = if (f.name()) |t| l.rel(t.offset, t.offset + @as(u32, @intCast(t.text.len))) else .none;
                        try fields.append(l.a, .{ .name = try l.tokenText(f.name()), .value = try l.exprOrMissing(f.value()), .name_range = name_range });
                    } else try fields.append(l.a, .{ .name = null, .value = try l.expr(item) });
                }
                break :blk .{ .init = .{ .ty = ty, .fields = fields.items } };
            },
            .container_decl => .{ .container = .{ .arg = try l.optExpr((ast.ContainerDecl{ .syntax = n }).argExpr()) } },
            .fn_proto => blk: {
                const proto = ast.FnProto{ .syntax = n };
                var params: std.ArrayList(ExprId) = .empty;
                var it = proto.params();
                while (it.next()) |p| if ((ast.Param{ .syntax = p }).typeExpr()) |t| try params.append(l.a, try l.expr(t));
                for (proto.clauses()) |c| if (c) |cn| {
                    _ = try l.clause(cn);
                };
                break :blk .{ .fn_type = .{ .params = params.items, .ret = try l.optExpr(proto.returnType()) } };
            },
            .return_expr => .{ .@"return" = try l.optExpr(firstChild(n)) },
            .break_expr => blk: {
                const b = ast.BreakExpr{ .syntax = n };
                break :blk .{ .@"break" = .{ .label = try l.tokenText(b.label()), .value = try l.optExpr(b.value()) } };
            },
            .continue_expr => blk: {
                // Same substructure as break: an optional label and an optional value
                const c = ast.BreakExpr{ .syntax = n };
                break :blk .{ .@"continue" = .{ .label = try l.tokenText(c.label()), .value = try l.optExpr(c.value()) } };
            },
            .comptime_expr => .{ .@"comptime" = try l.exprOrMissing(firstChild(n)) },
            .unreachable_expr => .@"unreachable",
            .optional_type => .{ .optional_type = try l.exprOrMissing(firstChild(n)) },
            .error_union_type => blk: {
                var it = ast.childNodes(n);
                break :blk .{ .error_union_type = .{ .err = try l.exprOrMissing(it.next()), .payload = try l.exprOrMissing(it.next()) } };
            },
            .ptr_type, .slice_type => return l.ptrType(n),
            .array_type => blk: {
                var it = ast.childNodes(n);
                const len = try l.exprOrMissing(it.next());
                var child: ?ExprId = null;
                var sentinel: ?ExprId = null;
                while (it.next()) |c| {
                    if (c.kind() == .sentinel) sentinel = try l.exprOrMissing(firstChild(c)) else child = try l.expr(c);
                }
                break :blk .{ .array_type = .{ .len = len, .child = child orelse try l.add(.missing, .none), .sentinel = sentinel } };
            },
            .error_set_decl => blk: {
                var names: std.ArrayList([]const u8) = .empty;
                var it = n.children();
                while (it.next()) |c| if (c == .token and c.token.kind == .identifier) try names.append(l.a, try l.ident(c.token.text));
                break :blk .{ .error_set = names.items };
            },
            .asm_output => blk: {
                // The output target is a direct token, not a subexpression; keep its actual range
                // and the current scope.
                if (n.childToken(.arrow) == null) {
                    var children = n.children();
                    var in_operand = false;
                    while (children.next()) |child| if (child == .token) {
                        const token = child.token;
                        if (token.kind == .l_paren) in_operand = true;
                        if (in_operand and token.kind == .identifier) {
                            const target = try l.add(.{ .name_ref = try l.ident(token.text) }, l.rel(token.offset, token.range().end));
                            break :blk .{ .other = try l.a.dupe(ExprId, &.{target}) };
                        }
                    };
                }
                break :blk .{ .other = try l.exprList(ast.childNodes(n)) };
            },
            else => .{ .other = try l.exprList(ast.childNodes(n)) },
        };
        return l.add(e, r);
    }

    fn block(l: *Lowerer, n: SyntaxNode) Error!ExprId {
        const blk = ast.Block{ .syntax = n };
        // Add a placeholder first: the label scope needs the ExprId of the block
        const id = try l.add(.missing, l.nodeRange(n));
        const saved = l.scope;
        defer l.scope = saved;
        const label = try l.tokenText(if (blk.label()) |lab| lab.name() else null);
        const inner = try l.pushScopeLabeled(&.{}, if (label) |name| .{ .name = name, .expr = id } else null);

        var stmts: std.ArrayList(Body.Stmt) = .empty;
        var it = blk.statements();
        while (it.next()) |s| {
            const kind = try l.stmt(s);
            try stmts.append(l.a, .{ .kind = kind, .end = s.range().end - l.base, .scope_after = l.scope });
        }
        l.exprs.items[@backingInt(id)] = .{ .block = .{ .label = label, .stmts = stmts.items, .scope = inner } };
        return id;
    }

    /// Lowers one block-level statement; a declaration advances the current scope to a child scope
    /// that contains the new binding
    fn stmt(l: *Lowerer, n: SyntaxNode) Error!@FieldType(Body.Stmt, "kind") {
        switch (n.kind()) {
            .var_decl => return .{ .local = try l.localDecl(n) },
            .defer_stmt => return .{ .@"defer" = try l.exprOrMissing(firstChild(n)) },
            .errdefer_stmt => return .{ .@"errdefer" = try l.exprOrMissing(firstChild(n)) },
            .comptime_stmt => {
                // `comptime var x = ...;` or `comptime { ... }` / `comptime expr;`
                const inner = firstChild(n) orelse return .{ .expr = try l.add(.missing, .none) };
                if (inner.kind() == .var_decl) {
                    const b = try l.localDecl(inner);
                    l.bindings.items[@backingInt(b)].is_comptime = true;
                    return .{ .local = b };
                }
                return .{ .expr = try l.add(.{ .@"comptime" = try l.expr(inner) }, l.nodeRange(n)) };
            },
            .destructure => {
                const d = ast.Destructure{ .syntax = n };
                const value = try l.exprOrMissing(d.value());
                var targets: std.ArrayList(Body.DestructureTarget) = .empty;
                var bindings: std.ArrayList(BindingId) = .empty;
                var it = d.targets();
                while (it.next()) |t| {
                    if (d.value()) |v| if (v.offset == t.offset) break;
                    if (ast.cast(ast.VarDecl, t)) |v| {
                        const name = v.name() orelse continue;
                        const ty = try l.optExpr(v.typeExpr());
                        // `align(...)` is evaluated in the enclosing scope, like the type
                        _ = try l.clauses(t);
                        const b = try l.bind(name, if (v.isConst()) .local_const else .local_var, .{ .ty = ty });
                        try bindings.append(l.a, b);
                        try targets.append(l.a, .{ .binding = b });
                    } else try targets.append(l.a, .{ .expr = try l.expr(t) });
                }
                if (bindings.items.len != 0) _ = try l.pushScope(bindings.items);
                return .{ .destructure = .{ .targets = targets.items, .value = value } };
            },
            else => return .{ .expr = try l.expr(n) },
        }
    }

    fn localDecl(l: *Lowerer, n: SyntaxNode) Error!BindingId {
        const v = ast.VarDecl{ .syntax = n };
        const ty = try l.optExpr(v.typeExpr());
        _ = try l.clauses(n);
        const init = try l.optExpr(v.initExpr());
        // When the name is missing, an empty name serves as a placeholder so that the statement
        // still has a binding
        const name = v.name() orelse SyntaxToken{ .kind = .identifier, .text = "", .offset = n.offset };
        const b = try l.bind(name, if (v.isConst()) .local_const else .local_var, .{ .ty = ty, .init = init });
        _ = try l.pushScope(&.{b});
        return b;
    }

    fn ifExpr(l: *Lowerer, n: SyntaxNode) Error!ExprId {
        const i = ast.IfExpr{ .syntax = n };
        const saved = l.scope;
        defer l.scope = saved;
        const cond = try l.exprOrMissing(i.cond());
        const caps = try l.captures(i.payload());
        if (caps.len != 0) _ = try l.pushScope(caps);
        const then = try l.exprOrMissing(i.then());
        l.scope = saved;
        var else_caps: []const BindingId = &.{};
        var else_expr: ?ExprId = null;
        if (i.@"else"()) |e| {
            else_caps = try l.captures(e.payload());
            if (else_caps.len != 0) _ = try l.pushScope(else_caps);
            else_expr = try l.exprOrMissing(e.body());
            l.scope = saved;
        }
        return l.add(.{ .@"if" = .{ .cond = cond, .capture = caps, .then = then, .else_capture = else_caps, .@"else" = else_expr } }, l.nodeRange(n));
    }

    fn loop(l: *Lowerer, n: SyntaxNode) Error!ExprId {
        const id = try l.add(.missing, l.nodeRange(n));
        const saved = l.scope;
        defer l.scope = saved;
        const is_for = n.kind() == .for_expr;
        const label_node = n.childNode(.label);
        const label = try l.tokenText(if (label_node) |lab| (ast.Label{ .syntax = lab }).name() else null);
        if (label) |name| _ = try l.pushScopeLabeled(&.{}, .{ .name = name, .expr = id });
        const outer = l.scope;

        var loop_data: Body.Loop = .{
            .kind = if (is_for) .@"for" else .@"while",
            .label = label,
            .inputs = &.{},
            .capture = &.{},
            .cont = null,
            .body = undefined,
            .else_capture = &.{},
            .@"else" = null,
            .is_inline = n.childToken(.keyword_inline) != null,
        };
        var else_clause: ?ast.ElseClause = null;
        if (is_for) {
            const f = ast.ForExpr{ .syntax = n };
            loop_data.inputs = try l.exprList(f.inputs());
            loop_data.capture = try l.captures(f.payload());
            if (loop_data.capture.len != 0) _ = try l.pushScope(loop_data.capture);
            loop_data.body = try l.exprOrMissing(f.body());
            else_clause = f.@"else"();
        } else {
            const w = ast.WhileExpr{ .syntax = n };
            loop_data.inputs = try l.a.dupe(ExprId, &.{try l.exprOrMissing(w.cond())});
            loop_data.capture = try l.captures(w.payload());
            if (loop_data.capture.len != 0) _ = try l.pushScope(loop_data.capture);
            loop_data.cont = try l.optExpr(w.continueExpr());
            loop_data.body = try l.exprOrMissing(w.body());
            else_clause = w.@"else"();
        }
        l.scope = outer;
        if (else_clause) |e| {
            loop_data.else_capture = try l.captures(e.payload());
            if (loop_data.else_capture.len != 0) _ = try l.pushScope(loop_data.else_capture);
            loop_data.@"else" = try l.exprOrMissing(e.body());
        }
        l.exprs.items[@backingInt(id)] = .{ .loop = loop_data };
        l.expr_scopes.items[@backingInt(id)] = saved;
        return id;
    }

    fn switchExpr(l: *Lowerer, n: SyntaxNode) Error!ExprId {
        const s = ast.SwitchExpr{ .syntax = n };
        const id = try l.add(.missing, l.nodeRange(n));
        const saved = l.scope;
        defer l.scope = saved;
        if (s.label()) |lab| if (lab.name()) |name| {
            _ = try l.pushScopeLabeled(&.{}, .{ .name = try l.ident(name.text), .expr = id });
        };
        const outer = l.scope;
        const operand = try l.exprOrMissing(s.operand());
        var prongs: std.ArrayList(Body.Prong) = .empty;
        var it = s.prongs();
        while (it.next()) |pn| {
            const p = ast.SwitchProng{ .syntax = pn };
            const items = try l.exprList(p.items());
            const caps = try l.captures(p.payload());
            if (caps.len != 0) _ = try l.pushScope(caps);
            try prongs.append(l.a, .{ .items = items, .is_else = p.isElse(), .is_inline = p.isInline(), .capture = caps, .body = try l.exprOrMissing(p.body()) });
            l.scope = outer;
        }
        l.exprs.items[@backingInt(id)] = .{ .@"switch" = .{ .operand = operand, .prongs = prongs.items } };
        return id;
    }

    fn ptrType(l: *Lowerer, n: SyntaxNode) Error!ExprId {
        const first = n.firstToken();
        const size: Body.PtrSize = if (n.kind() == .slice_type)
            .slice
        else if (first != null and first.?.kind == .l_bracket)
            (if (n.childToken(.identifier)) |t| (if (std.mem.eql(u8, t.text, "c")) Body.PtrSize.c else .many) else .many)
        else
            .one;
        var child: ?ExprId = null;
        var sentinel: ?ExprId = null;
        var it = ast.childNodes(n);
        while (it.next()) |c| switch (c.kind()) {
            .sentinel => sentinel = try l.exprOrMissing(firstChild(c)),
            .align_clause, .addrspace_clause => _ = try l.clause(c),
            else => child = try l.expr(c),
        };
        return l.add(.{ .ptr_type = .{
            .size = size,
            .is_const = n.childToken(.keyword_const) != null,
            .child = child orelse try l.add(.missing, .none),
            .sentinel = sentinel,
        } }, l.nodeRange(n));
    }
};

fn firstChild(n: SyntaxNode) ?SyntaxNode {
    var it = n.children();
    return it.nextNode();
}

/// Assignment operator: the first non-trivia token after the first child node
fn opAfterFirstNode(n: SyntaxNode) SyntaxKind {
    var it = n.children();
    var seen = false;
    while (it.next()) |e| switch (e) {
        .node => seen = true,
        .token => |t| if (seen and !isTrivia(t.kind)) return t.kind,
    };
    return .invalid;
}

const testing = std.testing;
const Parse = @import("../syntax/Parse.zig");

fn lowerFirst(text: []const u8) !struct { parse: *Parse, body: Body } {
    const p = try Parse.create(testing.allocator, text, .zig);
    errdefer p.destroy();
    var it = ast.childNodes(p.rootNode());
    return .{ .parse = p, .body = try lower(testing.allocator, it.next().?, .member) };
}

fn offsetOf(text: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, text, needle).?);
}

fn visibleNames(b: *const Body, offset: u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var s: ?ScopeId = b.scopeAt(offset);
    while (s) |id| : (s = b.scope(id).parent) {
        const bs = b.scope(id).bindings;
        var i = bs.len;
        while (i > 0) {
            i -= 1;
            try out.appendSlice(testing.allocator, b.binding(bs[i]).name);
            try out.append(testing.allocator, ' ');
        }
    }
    return out.toOwnedSlice(testing.allocator);
}

test "params, locals and captures are scoped" {
    const text =
        \\fn f(comptime T: type, x: T) !T {
        \\    const a = x;
        \\    if (opt) |v| {
        \\        var b = v;
        \\        _ = b;
        \\    } else |err| return err;
        \\    for (items, 0..) |item, i| _ = item;
        \\    const c = a catch |e| e;
        \\    // end
        \\}
    ;
    var r = try lowerFirst(text);
    defer r.parse.destroy();
    defer r.body.deinit(testing.allocator);
    const b = &r.body;
    try testing.expectEqual(2, b.params.len);
    try testing.expectEqual(.param, b.binding(b.params[1]).kind);

    const cases = [_]struct { at: []const u8, names: []const u8 }{
        // Parameter type: only the preceding parameters are visible
        .{ .at = "T) !T", .names = "T " },
        .{ .at = "x;", .names = "x T " },
        .{ .at = "v;", .names = "v a x T " },
        .{ .at = "_ = b", .names = "b v a x T " },
        .{ .at = "err;", .names = "err a x T " },
        .{ .at = "_ = item", .names = "i item a x T " },
        .{ .at = "e;", .names = "e a x T " },
        .{ .at = "// end", .names = "c a x T " },
    };
    for (cases) |c| {
        const names = try visibleNames(b, offsetOf(text, c.at));
        defer testing.allocator.free(names);
        testing.expectEqualStrings(c.names, names) catch |err| {
            std.debug.print("at \"{s}\"\n", .{c.at});
            return err;
        };
    }
}

test "expressions keep structure and ranges" {
    const text = "const x = std.mem.eql(u8, a.?, &b[0..1]) or foo.;";
    var r = try lowerFirst(text);
    defer r.parse.destroy();
    defer r.body.deinit(testing.allocator);
    const b = &r.body;
    const root = b.expr(b.value.?);
    try testing.expectEqual(.keyword_or, root.binary.op);
    const call = b.expr(root.binary.lhs).call;
    try testing.expectEqual(3, call.args.len);
    const callee = b.expr(call.callee).field_access;
    try testing.expectEqualStrings("eql", callee.field.?);
    try testing.expectEqualStrings("mem", b.expr(callee.lhs).field_access.field.?);
    try testing.expectEqual(.unwrap_optional, std.meta.activeTag(b.expr(call.args[1])));
    // `foo.`: the field is missing
    const incomplete = b.expr(root.binary.rhs).field_access;
    try testing.expect(incomplete.field == null);
    // Positions are relative to the start of the owner
    const r_eql = b.range(call.callee);
    try testing.expectEqualStrings("std.mem.eql", text[r_eql.start..r_eql.end]);
    try testing.expectEqual(call.callee, b.exprAt(offsetOf(text, ".eql") + 1).?);
}

test "labels, switch captures and nested containers" {
    const text =
        \\fn g() void {
        \\    outer: while (true) {
        \\        switch (u) { .a => |p| break :outer, else => {} }
        \\    }
        \\    const S = struct { fn h() void {} };
        \\    _ = S;
        \\}
    ;
    var r = try lowerFirst(text);
    defer r.parse.destroy();
    defer r.body.deinit(testing.allocator);
    const b = &r.body;
    // Label scope
    var s: ?ScopeId = b.scopeAt(offsetOf(text, "break"));
    var found_label = false;
    while (s) |id| : (s = b.scope(id).parent) {
        if (b.scope(id).label) |lab| if (std.mem.eql(u8, lab.name, "outer")) {
            found_label = true;
        };
    }
    try testing.expect(found_label);
    const names = try visibleNames(b, offsetOf(text, "break"));
    defer testing.allocator.free(names);
    try testing.expectEqualStrings("p ", names);
    // A container in the body is only a placeholder; its members are not expanded
    var containers: usize = 0;
    for (b.exprs) |e| if (e == .container) {
        containers += 1;
    };
    try testing.expectEqual(1, containers);
}

test "recovered invalid names remain unknown while preserving enclosing bindings" {
    const cases = [_]struct { source: []const u8, type_position: bool }{
        .{ .source = "fn f(input: u32) void { const value: @\"EdgeWidg\n = input; _ = value; _ = input; }", .type_position = true },
        .{ .source = "fn f(input: u32) void { const value = @\"EdgeWidg", .type_position = false },
    };
    for (cases) |case| {
        var result = try lowerFirst(case.source);
        defer result.parse.destroy();
        defer result.body.deinit(testing.allocator);
        const body = &result.body;
        const binding = for (body.bindings) |item| {
            if (std.mem.eql(u8, item.name, "value")) break item;
        } else return error.MissingRecoveredBinding;
        const expr = if (case.type_position) binding.ty.? else binding.init.?;
        try testing.expect(body.expr(expr) == .missing);
        try testing.expectEqual(expr, body.exprAt(offsetOf(case.source, "@\"") + 2).?);
        const input = body.lookup(body.expr_scopes[@backingInt(expr)], "input").?;
        try testing.expectEqual(.param, body.binding(input).kind);
        if (case.type_position) {
            var saw_input_ref = false;
            for (body.exprs) |e| if (e == .name_ref and std.mem.eql(u8, e.name_ref, "input")) {
                saw_input_ref = true;
            };
            try testing.expect(saw_input_ref);
        }
    }
}

test "zon root expression is the value; inf and nan are literals" {
    const text = "// c\n.{ .a = inf, .b = -nan, .c = @\"inf\", .d = .{ x, 1 } }";
    const p = try Parse.create(testing.allocator, text, .zon);
    defer p.destroy();
    const root = @import("../syntax/ItemTree.zig").zonRoot(p.rootNode()).?;
    var body = try lower(testing.allocator, root, .zon);
    defer body.deinit(testing.allocator);
    const fields = body.expr(body.value.?).init.fields;
    try testing.expectEqual(4, fields.len);
    try testing.expectEqualStrings("inf", body.expr(fields[0].value).literal);
    try testing.expectEqualStrings("nan", body.expr(body.expr(fields[1].value).prefix.operand).literal);
    // A quoted identifier is not a float literal
    try testing.expectEqualStrings("inf", body.expr(fields[2].value).name_ref);
    try testing.expectEqualStrings("x", body.expr(body.expr(fields[3].value).init.fields[0].value).name_ref);
    // Positions are relative to the start of the root expression
    const r = body.range(fields[0].value);
    try testing.expectEqualStrings("inf", text[root.offset + r.start .. root.offset + r.end]);

    // In a Zig file `inf` is a name
    var zig = try lowerFirst("const x = inf;");
    defer zig.parse.destroy();
    defer zig.body.deinit(testing.allocator);
    try testing.expectEqualStrings("inf", zig.body.expr(zig.body.value.?).name_ref);
}
