//! CST → HIR 降级（设计 §8.2），同时计算局部作用域（§8.3）。

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

/// 降级一个容器成员（fn_decl / var_decl / container_field / test_decl / comptime_decl）
pub fn lower(gpa: Allocator, member: SyntaxNode) Error!Body {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var l: Lowerer = .{ .gpa = gpa, .a = arena.allocator(), .base = member.offset };
    defer l.deinit();
    try l.scopes.append(gpa, .{ .parent = null, .bindings = &.{} });

    var value: ?ExprId = null;
    var type_expr: ?ExprId = null;
    var params: std.ArrayList(BindingId) = .empty;
    switch (member.kind()) {
        .fn_decl => {
            const decl = ast.cast(ast.FnDecl, member).?;
            if (decl.proto()) |proto| {
                // 每个参数的类型在之前参数的作用域中求值：`fn f(comptime T: type, x: T)`
                var it = proto.params();
                while (it.next()) |p| {
                    const param = ast.cast(ast.Param, p).?;
                    const ty = try l.optExpr(param.typeExpr());
                    const name = param.name() orelse continue;
                    const b = try l.bind(name, .param, .{ .ty = ty, .is_comptime = param.isComptime() });
                    try params.append(l.a, b);
                    _ = try l.pushScope(&.{b});
                }
                for (proto.clauses()) |c| if (c) |n| {
                    _ = try l.expr(n);
                };
                type_expr = try l.optExpr(proto.returnType());
            }
            if (decl.body()) |b| value = try l.expr(b.syntax);
        },
        .var_decl => {
            const decl = ast.cast(ast.VarDecl, member).?;
            type_expr = try l.optExpr(decl.typeExpr());
            try l.clauses(member);
            value = try l.optExpr(decl.initExpr());
        },
        .container_field => {
            const field = ast.cast(ast.ContainerField, member).?;
            type_expr = try l.optExpr(field.typeExpr());
            try l.clauses(member);
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
    };
    body.arena = arena.state;
    return body;
}

const Lowerer = struct {
    gpa: Allocator,
    /// Body 的 arena：名字与各种切片
    a: Allocator,
    /// owner 节点起点
    base: u32,
    exprs: std.ArrayList(Expr) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    expr_scopes: std.ArrayList(ScopeId) = .empty,
    bindings: std.ArrayList(Body.Binding) = .empty,
    scopes: std.ArrayList(Body.Scope) = .empty,
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

    /// token 的文本；`@"name"` 形式的标识符取去掉引号的名字
    fn tokenText(l: *Lowerer, t: ?SyntaxToken) Error!?[]const u8 {
        return if (t) |tok| try l.str(ast.identName(tok.text)) else null;
    }

    /// 新建当前作用域的子作用域并进入
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
            .name = try l.str(ast.identName(name.text)),
            .kind = kind,
            .range = l.rel(r.start, r.end),
            .ty = extra.ty,
            .init = extra.init,
            .is_ptr = extra.is_ptr,
            .is_comptime = extra.is_comptime,
        });
        return id;
    }

    /// 捕获 `|a, *b|` 的绑定
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

    /// align / addrspace / linksection / callconv 子句中的表达式
    fn clauses(l: *Lowerer, n: SyntaxNode) Error!void {
        var it = n.children();
        while (it.nextNode()) |c| switch (c.kind()) {
            .align_clause, .addrspace_clause, .linksection_clause, .callconv_clause => _ = try l.expr(c),
            else => {},
        };
    }

    fn expr(l: *Lowerer, n: SyntaxNode) Error!ExprId {
        const r = l.nodeRange(n);
        const e: Expr = switch (n.kind()) {
            // 括号与语句形式的分支不单独成节点
            .paren_expr, .expr_stmt => return l.exprOrMissing(firstChild(n)),
            .name_ref => .{ .name_ref = try l.str(ast.identName((ast.NameRef{ .syntax = n }).name().?.text)) },
            .literal => .{ .literal = try l.tokenText(n.firstToken()) orelse "" },
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
                    _ = try l.expr(cn);
                };
                break :blk .{ .fn_type = .{ .params = params.items, .ret = try l.optExpr(proto.returnType()) } };
            },
            .return_expr => .{ .@"return" = try l.optExpr(firstChild(n)) },
            .break_expr => blk: {
                const b = ast.BreakExpr{ .syntax = n };
                break :blk .{ .@"break" = .{ .label = try l.tokenText(b.label()), .value = try l.optExpr(b.value()) } };
            },
            .continue_expr => blk: {
                // 与 break 的子结构相同：可选标签与可选的值
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
                while (it.next()) |c| if (c == .token and c.token.kind == .identifier) try names.append(l.a, try l.str(ast.identName(c.token.text)));
                break :blk .{ .error_set = names.items };
            },
            else => .{ .other = try l.exprList(ast.childNodes(n)) },
        };
        return l.add(e, r);
    }

    fn block(l: *Lowerer, n: SyntaxNode) Error!ExprId {
        const blk = ast.Block{ .syntax = n };
        // 先占位，标签作用域需要块的 ExprId
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

    /// 降级一条块级语句；声明会把当前作用域推进到包含新绑定的子作用域
    fn stmt(l: *Lowerer, n: SyntaxNode) Error!@FieldType(Body.Stmt, "kind") {
        switch (n.kind()) {
            .var_decl => return .{ .local = try l.localDecl(n) },
            .defer_stmt => return .{ .@"defer" = try l.exprOrMissing(firstChild(n)) },
            .errdefer_stmt => {
                const saved = l.scope;
                defer l.scope = saved;
                const caps = try l.captures(if (n.childNode(.payload)) |p| ast.Payload{ .syntax = p } else null);
                if (caps.len != 0) _ = try l.pushScope(caps);
                var it = ast.childNodes(n);
                it.skip = .payload;
                return .{ .@"errdefer" = .{ .capture = if (caps.len != 0) caps[0] else null, .body = try l.exprOrMissing(it.next()) } };
            },
            .comptime_stmt => {
                // `comptime var x = ...;` 或 `comptime { ... }` / `comptime expr;`
                const inner = firstChild(n) orelse return .{ .expr = try l.add(.missing, .none) };
                if (inner.kind() == .var_decl) return .{ .local = try l.localDecl(inner) };
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
                        const b = try l.bind(name, if (v.isConst()) .local_const else .local_var, .{ .ty = try l.optExpr(v.typeExpr()) });
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
        try l.clauses(n);
        const init = try l.optExpr(v.initExpr());
        // 缺名字时用空名占位，保证语句仍有绑定
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
            _ = try l.pushScopeLabeled(&.{}, .{ .name = try l.str(ast.identName(name.text)), .expr = id });
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
            try prongs.append(l.a, .{ .items = items, .is_else = p.isElse(), .capture = caps, .body = try l.exprOrMissing(p.body()) });
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
            .align_clause, .addrspace_clause => _ = try l.expr(c),
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

/// 赋值运算符：第一个子节点之后的第一个非 trivia token
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
    const p = try Parse.create(testing.allocator, text);
    errdefer p.destroy();
    var it = ast.childNodes(p.rootNode());
    return .{ .parse = p, .body = try lower(testing.allocator, it.next().?) };
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
        // 参数类型：只看得到之前的参数
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
    // `foo.` 字段缺失
    const incomplete = b.expr(root.binary.rhs).field_access;
    try testing.expect(incomplete.field == null);
    // 位置相对 owner 起点
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
    // 标签作用域
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
    // 体内容器只是占位，不展开其成员
    var containers: usize = 0;
    for (b.exprs) |e| if (e == .container) {
        containers += 1;
    };
    try testing.expectEqual(1, containers);
}
