//! Zig grammar rules (error-tolerant recursive descent).
//!
//! The rules follow the PEG grammar in the langref, with specific decisions consistent with
//! `std.zig.Parse`; the difference is that any failure only records an error and continues,
//! guaranteeing a complete syntax tree for any input.
//!
//! Convention: functions returning `?CompletedMarker` return null without consuming any token
//! when the current token cannot start that construct.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const Marker = parser_mod.Marker;
const CompletedMarker = parser_mod.CompletedMarker;
const SyntaxKind = @import("kind.zig").SyntaxKind;

const Error = Allocator.Error;
const CM = ?CompletedMarker;

// ── Top level and containers ──────────────────────────────────────────

pub fn sourceFile(p: *Parser) Error!void {
    const m = try p.start();
    try containerMembers(p);
    // Stray `}` and the like at the top level
    while (!p.atEof()) {
        try p.errBump("unexpected token");
        try containerMembers(p);
    }
    _ = try m.complete(p, .source_file);
}

/// A ZON file: one expression, parsed like a Zig expression (whether it stays within the ZON subset
/// is diagnosed by `zig ast-check --zon`). Each token before the expression that cannot start one
/// (such as a doc comment) is wrapped in its own error node; extra tokens after it go into one
/// error node
pub fn zonFile(p: *Parser) Error!void {
    const m = try p.start();
    var root: CM = null;
    var junk = false;
    while (!p.atEof()) {
        root = try expr(p);
        if (root != null) break;
        if (!junk) try p.err("expected expression");
        junk = true;
        const e = try p.start();
        try p.bump();
        _ = try e.complete(p, .error_node);
    }
    if (root == null and !junk) try p.err("expected expression");
    if (!p.atEof()) {
        try p.err("expected end of file");
        const e = try p.start();
        while (!p.atEof()) try p.bump();
        _ = try e.complete(p, .error_node);
    }
    _ = try m.complete(p, .source_file);
}

/// Parses container members up to `}` or the end of the file (does not consume `}`).
fn containerMembers(p: *Parser) Error!void {
    while (p.at(.container_doc_comment)) try p.bump();
    while (true) {
        switch (p.peek()) {
            .eof, .r_brace => return,
            else => {},
        }
        const before = p.pos;
        try containerMember(p);
        if (p.pos == before) try p.errBump("expected container member");
    }
}

fn containerMember(p: *Parser) Error!void {
    const m = try p.start();
    const has_doc = p.at(.doc_comment);
    while (p.at(.doc_comment)) try p.bump();

    switch (p.peek()) {
        .keyword_test => return testDecl(p, m),
        .keyword_comptime => if (p.nth(1) == .l_brace) return comptimeDecl(p, m),
        .keyword_pub, .keyword_const, .keyword_var, .keyword_threadlocal, .keyword_export, .keyword_fn, .keyword_noinline => return decl(p, m),
        .keyword_extern => switch (p.nth(1)) {
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {},
            else => return decl(p, m),
        },
        .keyword_inline => switch (p.nth(1)) {
            .keyword_for, .keyword_while => {},
            else => return decl(p, m),
        },
        .eof, .r_brace => {
            if (has_doc) {
                try p.err("doc comment not attached to a declaration");
                _ = try m.complete(p, .error_node);
            } else m.abandon(p);
            return;
        },
        else => {},
    }

    if (!atTypeExprStart(p) and !p.at(.keyword_comptime)) {
        if (has_doc) _ = try m.complete(p, .error_node) else m.abandon(p);
        return p.errBump("expected container member");
    }
    try containerField(p, m);
    switch (p.peek()) {
        .comma => try p.bump(),
        .r_brace, .eof => {},
        else => try p.err("expected ',' after field"),
    }
}

fn testDecl(p: *Parser, m: Marker) Error!void {
    try p.bump(); // test
    if (p.at(.string_literal) or p.at(.identifier)) try p.bump();
    if (try block(p, null) == null) try p.err("expected block");
    _ = try m.complete(p, .test_decl);
}

fn comptimeDecl(p: *Parser, m: Marker) Error!void {
    try p.bump(); // comptime
    _ = try block(p, null);
    _ = try m.complete(p, .comptime_decl);
}

fn decl(p: *Parser, m: Marker) Error!void {
    _ = try p.eat(.keyword_pub);
    switch (p.peek()) {
        .keyword_extern => {
            try p.bump();
            _ = try p.eat(.string_literal);
        },
        .keyword_export, .keyword_inline, .keyword_noinline => try p.bump(),
        else => {},
    }
    if (p.at(.keyword_fn)) {
        _ = try fnProto(p);
        if (p.at(.l_brace)) {
            _ = try block(p, null);
        } else if (!try p.eat(.semicolon)) {
            try p.err("expected ';' or '{'");
        }
        _ = try m.complete(p, .fn_decl);
        return;
    }
    _ = try p.eat(.keyword_threadlocal);
    if (p.at(.keyword_const) or p.at(.keyword_var)) {
        try varDeclProto(p);
        try varDeclInit(p);
        _ = try p.expect(.semicolon);
        _ = try m.complete(p, .var_decl);
        return;
    }
    try p.err("expected function or variable declaration");
    _ = try m.complete(p, .error_node);
}

/// `(const|var) name [: Type] [align] [addrspace] [linksection]`;
/// the current token must be const/var.
fn varDeclProto(p: *Parser) Error!void {
    try p.bump();
    _ = try p.expect(.identifier);
    if (try p.eat(.colon)) {
        if (try typeExpr(p) == null) try p.err("expected type");
    }
    _ = try byteAlign(p);
    _ = try clause(p, .keyword_addrspace, .addrspace_clause);
    _ = try clause(p, .keyword_linksection, .linksection_clause);
}

fn varDeclInit(p: *Parser) Error!void {
    if (p.at(.equal) or p.at(.equal_equal)) {
        if (p.at(.equal_equal)) try p.err("variable declaration should use '='");
        try p.bump();
        if (try expr(p) == null) try p.err("expected expression");
    }
}

fn containerField(p: *Parser, m: Marker) Error!void {
    _ = try p.eat(.keyword_comptime);
    if (p.at(.identifier) and p.nth(1) == .colon) {
        try p.bump();
        try p.bump();
    }
    if (try typeExpr(p) == null) try p.err("expected field type");
    _ = try byteAlign(p);
    if (try p.eat(.equal)) {
        if (try expr(p) == null) try p.err("expected expression");
    }
    _ = try m.complete(p, .container_field);
}

fn fnProto(p: *Parser) Error!CompletedMarker {
    const m = try p.start();
    try p.bump(); // fn
    _ = try p.eat(.identifier);
    try paramList(p);
    _ = try byteAlign(p);
    _ = try clause(p, .keyword_addrspace, .addrspace_clause);
    _ = try clause(p, .keyword_linksection, .linksection_clause);
    _ = try clause(p, .keyword_callconv, .callconv_clause);
    _ = try p.eat(.bang);
    // After an unclosed parameter list, the next declaration is not the return type
    if (atContainerDecl(p) or try typeExpr(p) == null) try p.err("expected return type");
    return m.complete(p, .fn_proto);
}

fn paramList(p: *Parser) Error!void {
    const m = try p.start();
    if (!try p.expect(.l_paren)) {
        _ = try m.complete(p, .param_list);
        return;
    }
    while (true) {
        if (try p.eat(.r_paren)) break;
        switch (p.peek()) {
            .eof, .l_brace, .r_brace, .semicolon => {
                try p.err("expected ')'");
                break;
            },
            else => if (atListEnd(p)) {
                try p.err("expected ')'");
                break;
            },
        }
        const before = p.pos;
        try param(p);
        if (p.pos == before) {
            try p.errBump("expected parameter");
            continue;
        }
        switch (p.peek()) {
            .comma => try p.bump(),
            .r_paren => {},
            .colon, .r_brace, .r_bracket => {
                try p.err("expected ')'");
                break;
            },
            else => if (!atListEnd(p)) try p.err("expected ',' after parameter"),
        }
    }
    _ = try m.complete(p, .param_list);
}

/// Whether the current token starts a declaration that is never a statement or an expression:
/// a list or block still open there is unclosed, and the declaration belongs to the container
/// (`fn` with a name: a function type cannot have one)
fn atContainerDecl(p: *Parser) bool {
    return switch (p.peek()) {
        .keyword_pub, .keyword_test, .keyword_export, .keyword_threadlocal, .keyword_noinline => true,
        .keyword_extern => switch (p.nth(1)) {
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => false,
            else => true,
        },
        .keyword_fn => p.nth(1) == .identifier,
        .keyword_inline => p.nth(1) == .keyword_fn,
        else => false,
    };
}

/// Whether the current token cannot start or continue an element of a parameter, argument,
/// initializer or error set list, but starts a declaration: the list is unclosed and ends here
fn atListEnd(p: *Parser) bool {
    return p.at(.keyword_const) or p.at(.keyword_var) or atContainerDecl(p);
}

fn param(p: *Parser) Error!void {
    const m = try p.start();
    const documented = p.at(.doc_comment);
    while (p.at(.doc_comment)) try p.bump();
    if (p.at(.ellipsis3)) {
        if (documented and !p.variadic_doc_comments) try p.err("expected parameter type");
        try p.bump();
        _ = try m.complete(p, .param);
        return;
    }
    if (p.at(.keyword_noalias) or p.at(.keyword_comptime)) try p.bump();
    if (p.at(.identifier) and p.nth(1) == .colon) {
        try p.bump();
        try p.bump();
    }
    if (!try p.eat(.keyword_anytype)) {
        if (try typeExpr(p) == null) {
            // Do not produce an empty node when nothing was parsed
            if (p.events.items.len == m.index + 1) {
                m.abandon(p);
                return;
            }
            try p.err("expected parameter type");
        }
    }
    _ = try m.complete(p, .param);
}

/// `align(expr)` or the bit-field form `align(expr:expr:expr)`
fn byteAlign(p: *Parser) Error!CM {
    if (!p.at(.keyword_align)) return null;
    const m = try p.start();
    try p.bump();
    _ = try p.expect(.l_paren);
    if (try expr(p) == null) try p.err("expected expression");
    if (try p.eat(.colon)) {
        if (try expr(p) == null) try p.err("expected expression");
        _ = try p.expect(.colon);
        if (try expr(p) == null) try p.err("expected expression");
    }
    _ = try p.expect(.r_paren);
    return try m.complete(p, .align_clause);
}

/// Clause of the form `keyword(expr)`: addrspace / linksection / callconv
fn clause(p: *Parser, comptime keyword: SyntaxKind, comptime kind: SyntaxKind) Error!CM {
    if (!p.at(keyword)) return null;
    const m = try p.start();
    try p.bump();
    _ = try p.expect(.l_paren);
    if (try expr(p) == null) try p.err("expected expression");
    _ = try p.expect(.r_paren);
    return try m.complete(p, kind);
}

// ── Statements ───────────────────────────────────────────────────────

/// `{ statements }`; a non-null `m` is an already started node (e.g. the label has already
/// been consumed).
fn block(p: *Parser, started: ?Marker) Error!CM {
    if (!p.at(.l_brace)) {
        if (started) |m| {
            try p.err("expected '{'");
            return try m.complete(p, .block);
        }
        return null;
    }
    const m = started orelse try p.start();
    try p.bump();
    while (true) {
        switch (p.peek()) {
            .r_brace, .eof => break,
            // The block is unclosed: the declaration belongs to the enclosing container
            else => if (atContainerDecl(p)) break,
        }
        const before = p.pos;
        try statement(p, true);
        if (p.pos == before) try p.errBump("expected statement");
    }
    _ = try p.expect(.r_brace);
    return try m.complete(p, .block);
}

fn atBlockExprStart(p: *Parser) bool {
    return p.at(.l_brace) or (p.at(.identifier) and p.nth(1) == .colon and p.nth(2) == .l_brace);
}

/// `[label:] { ... }`
pub fn blockExpr(p: *Parser) Error!CM {
    if (p.at(.l_brace)) return block(p, null);
    if (!atBlockExprStart(p)) return null;
    const m = try p.start();
    try label(p);
    return block(p, m);
}

fn label(p: *Parser) Error!void {
    const m = try p.start();
    try p.bump();
    try p.bump();
    _ = try m.complete(p, .label);
}

fn statement(p: *Parser, block_level: bool) Error!void {
    switch (p.peek()) {
        .keyword_comptime => {
            const n1 = p.nth(1);
            if (n1 == .l_brace or (n1 == .identifier and p.nth(2) == .colon and p.nth(3) == .l_brace)) {
                const m = try p.start();
                try p.bump();
                _ = try blockExpr(p);
                _ = try m.complete(p, .comptime_stmt);
                return;
            }
            if (block_level) return varAssignStatement(p);
            const m = try p.start();
            try p.bump();
            if (try assignExpr(p) == null) try p.err("expected expression");
            _ = try p.expect(.semicolon);
            _ = try m.complete(p, .comptime_stmt);
            return;
        },
        .keyword_nosuspend => return prefixedStatement(p, .nosuspend_stmt),
        .keyword_suspend => return prefixedStatement(p, .suspend_stmt),
        .keyword_defer => if (block_level) return prefixedStatement(p, .defer_stmt),
        .keyword_errdefer => if (block_level) return prefixedStatement(p, .errdefer_stmt),
        .keyword_if => {
            const m = try p.start();
            _ = try ifExpr(p, m, .statement);
            return;
        },
        else => {},
    }

    if (try labeledStatement(p)) return;

    if (block_level) return varAssignStatement(p);
    const m = try p.start();
    if (try assignExpr(p) == null) {
        m.abandon(p);
        return;
    }
    _ = try p.expect(.semicolon);
    _ = try m.complete(p, .expr_stmt);
}

/// Prefixed statements: the keyword followed by a block or an expression statement (no capture).
fn prefixedStatement(p: *Parser, kind: SyntaxKind) Error!void {
    const m = try p.start();
    try p.bump();
    try blockExprStatement(p);
    _ = try m.complete(p, kind);
}

fn blockExprStatement(p: *Parser) Error!void {
    if (try blockExpr(p) != null) return;
    if (try assignExpr(p) == null) {
        try p.err("expected block or expression");
        return;
    }
    _ = try p.expect(.semicolon);
}

/// `[label:] (block / loop / switch)`; returns false when not at one of these constructs.
fn labeledStatement(p: *Parser) Error!bool {
    var has_label = false;
    if (p.at(.identifier) and p.nth(1) == .colon) {
        switch (p.nth(2)) {
            .l_brace, .keyword_inline, .keyword_for, .keyword_while, .keyword_switch => has_label = true,
            else => return false,
        }
    }
    switch (if (has_label) p.nth(2) else p.peek()) {
        .l_brace, .keyword_inline, .keyword_for, .keyword_while, .keyword_switch => {},
        else => return false,
    }
    const m = try p.start();
    if (has_label) try label(p);
    switch (p.peek()) {
        .l_brace => _ = try block(p, m),
        .keyword_switch => _ = try switchExpr(p, m),
        else => _ = try loop(p, m, .statement),
    }
    return true;
}

/// Block-level statement: variable declaration, assignment, destructuring, or expression statement.
fn varAssignStatement(p: *Parser) Error!void {
    const sm = try p.start();
    const has_comptime = try p.eat(.keyword_comptime);

    var lhs_count: usize = 0;
    var first_expr: CM = null;
    while (true) {
        if (p.at(.keyword_const) or p.at(.keyword_var)) {
            const vm = try p.start();
            try varDeclProto(p);
            if (lhs_count == 0 and !p.at(.comma)) {
                // Single variable declaration: `var x = expr;`
                if (!p.at(.equal) and !p.at(.equal_equal)) try p.err("expected '='");
                try varDeclInit(p);
                _ = try p.expect(.semicolon);
                _ = try vm.complete(p, .var_decl);
                if (has_comptime) _ = try sm.complete(p, .comptime_stmt) else sm.abandon(p);
                return;
            }
            _ = try vm.complete(p, .var_decl);
        } else {
            const e = try expr(p) orelse {
                if (lhs_count == 0) {
                    if (has_comptime) {
                        try p.err("expected statement");
                        _ = try sm.complete(p, .comptime_stmt);
                    } else sm.abandon(p);
                    return;
                }
                try p.err("expected expression or variable declaration");
                break;
            };
            if (lhs_count == 0) first_expr = e;
        }
        lhs_count += 1;
        if (!try p.eat(.comma)) break;
    }

    if (lhs_count == 1 and first_expr != null) {
        if (isAssignOp(p.peek())) {
            const am = try first_expr.?.precede(p);
            try p.bump();
            if (try expr(p) == null) try p.err("expected expression");
            _ = try am.complete(p, .assign_expr);
        }
        _ = try p.expect(.semicolon);
        _ = try sm.complete(p, if (has_comptime) .comptime_stmt else .expr_stmt);
        return;
    }

    // Destructuring: `a, var b = expr;`
    _ = try p.expect(.equal);
    if (try expr(p) == null) try p.err("expected expression");
    _ = try p.expect(.semicolon);
    _ = try sm.complete(p, .destructure);
}

fn isAssignOp(kind: SyntaxKind) bool {
    return switch (kind) {
        .equal,
        .asterisk_equal,
        .slash_equal,
        .percent_equal,
        .plus_equal,
        .minus_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .angle_bracket_angle_bracket_right_equal,
        .ampersand_equal,
        .caret_equal,
        .pipe_equal,
        .asterisk_percent_equal,
        .plus_percent_equal,
        .minus_percent_equal,
        .asterisk_pipe_equal,
        .plus_pipe_equal,
        .minus_pipe_equal,
        => true,
        else => false,
    };
}

/// `Expr (AssignOp Expr / (, Expr)+ = Expr)?`
fn assignExpr(p: *Parser) Error!CM {
    const lhs = try expr(p) orelse return null;
    if (p.at(.comma)) {
        const m = try lhs.precede(p);
        while (try p.eat(.comma)) {
            if (try expr(p) == null) try p.err("expected expression");
        }
        _ = try p.expect(.equal);
        if (try expr(p) == null) try p.err("expected expression");
        return try m.complete(p, .destructure);
    }
    return try finishAssign(p, lhs);
}

fn singleAssignExpr(p: *Parser) Error!CM {
    const lhs = try expr(p) orelse return null;
    return try finishAssign(p, lhs);
}

fn finishAssign(p: *Parser, lhs: CompletedMarker) Error!CompletedMarker {
    if (!isAssignOp(p.peek())) return lhs;
    const m = try lhs.precede(p);
    try p.bump();
    if (try expr(p) == null) try p.err("expected expression");
    return m.complete(p, .assign_expr);
}

// ── Control flow ─────────────────────────────────────────────────────

/// Body form of a control-flow construct: statement level (the then branch may be
/// `expression;`), expression, or type expression.
const Form = enum { statement, expr, type };

fn ifExpr(p: *Parser, m: Marker, form: Form) Error!CompletedMarker {
    try p.bump(); // if
    _ = try p.expect(.l_paren);
    if (try expr(p) == null) try p.err("expected condition expression");
    _ = try p.expect(.r_paren);
    try optPayload(p);
    try bodyAndElse(p, form, true);
    return m.complete(p, .if_expr);
}

fn whileExpr(p: *Parser, m: Marker, form: Form) Error!CompletedMarker {
    try p.bump(); // while
    _ = try p.expect(.l_paren);
    if (try expr(p) == null) try p.err("expected condition expression");
    _ = try p.expect(.r_paren);
    try optPayload(p);
    if (p.at(.colon)) {
        const cm = try p.start();
        try p.bump();
        _ = try p.expect(.l_paren);
        if (try assignExpr(p) == null) try p.err("expected expression");
        _ = try p.expect(.r_paren);
        _ = try cm.complete(p, .while_continue);
    }
    try bodyAndElse(p, form, true);
    return m.complete(p, .while_expr);
}

fn forExpr(p: *Parser, m: Marker, form: Form) Error!CompletedMarker {
    try p.bump(); // for
    try forInputs(p);
    if (p.at(.pipe)) try optPayload(p) else try p.err("expected loop capture");
    try bodyAndElse(p, form, false);
    return m.complete(p, .for_expr);
}

fn forInputs(p: *Parser) Error!void {
    const m = try p.start();
    if (!try p.expect(.l_paren)) {
        _ = try m.complete(p, .for_inputs);
        return;
    }
    while (true) {
        if (try p.eat(.r_paren)) break;
        switch (p.peek()) {
            .eof, .l_brace, .r_brace, .pipe => {
                try p.err("expected ')'");
                break;
            },
            else => {},
        }
        const input = try expr(p) orelse {
            try p.errBump("expected expression");
            continue;
        };
        if (p.at(.ellipsis2)) {
            const rm = try input.precede(p);
            try p.bump();
            _ = try expr(p);
            _ = try rm.complete(p, .for_input);
        }
        switch (p.peek()) {
            .comma => try p.bump(),
            .r_paren => {},
            .colon, .r_brace, .r_bracket => {
                try p.err("expected ')'");
                break;
            },
            else => try p.err("expected ','"),
        }
    }
    _ = try m.complete(p, .for_inputs);
}

/// `inline? (for / while)`
fn loop(p: *Parser, m: Marker, form: Form) Error!CompletedMarker {
    _ = try p.eat(.keyword_inline);
    return switch (p.peek()) {
        .keyword_for => forExpr(p, m, form),
        .keyword_while => whileExpr(p, m, form),
        else => {
            try p.err("expected 'for' or 'while'");
            return m.complete(p, .error_node);
        },
    };
}

const BodyEnd = enum {
    /// An else may follow the body
    open,
    /// In statement form, ends with `;` and no else may follow
    closed,
    /// In statement form, the body is a block and the else is optional
    block,
};

fn body(p: *Parser, form: Form) Error!BodyEnd {
    switch (form) {
        .statement => {
            if (try blockExpr(p) != null) return .block;
            if (try assignExpr(p) == null) {
                try p.err("expected block or expression");
                return .closed;
            }
            if (try p.eat(.semicolon)) return .closed;
            return .open;
        },
        .expr => if (try expr(p) == null) try p.err("expected expression"),
        .type => if (try typeExpr(p) == null) try p.err("expected type expression"),
    }
    return .block;
}

fn bodyAndElse(p: *Parser, form: Form, allow_payload: bool) Error!void {
    switch (try body(p, form)) {
        .open => try elseClause(p, form, allow_payload, true),
        .block => try elseClause(p, form, allow_payload, false),
        .closed => {},
    }
}

fn elseClause(p: *Parser, form: Form, allow_payload: bool, required: bool) Error!void {
    if (!p.at(.keyword_else)) {
        if (required) try p.err("expected ';' or 'else'");
        return;
    }
    const m = try p.start();
    try p.bump();
    if (allow_payload) try optPayload(p);
    switch (form) {
        .statement => try statement(p, false),
        .expr => if (try expr(p) == null) try p.err("expected expression"),
        .type => if (try typeExpr(p) == null) try p.err("expected type expression"),
    }
    _ = try m.complete(p, .else_clause);
}

/// `|x|`, `|*x|`, `|x, i|`, `|*a, b, c|`: all forms are accepted uniformly.
fn optPayload(p: *Parser) Error!void {
    if (!p.at(.pipe)) return;
    const m = try p.start();
    try p.bump();
    while (true) {
        _ = try p.eat(.asterisk);
        _ = try p.expect(.identifier);
        if (!try p.eat(.comma)) break;
        if (p.at(.pipe)) break;
    }
    _ = try p.expect(.pipe);
    _ = try m.complete(p, .payload);
}

fn switchExpr(p: *Parser, m: Marker) Error!CompletedMarker {
    try p.bump(); // switch
    _ = try p.expect(.l_paren);
    if (try expr(p) == null) try p.err("expected expression");
    _ = try p.expect(.r_paren);
    if (try p.expect(.l_brace)) {
        while (true) {
            switch (p.peek()) {
                .r_brace, .eof => break,
                else => {},
            }
            // A token that cannot start a prong (such as a `const` statement after an unclosed
            // switch) ends the prong list, as in `std.zig.Parse`
            const before = p.pos;
            try switchProng(p);
            if (p.pos == before) break;
            switch (p.peek()) {
                .comma => try p.bump(),
                .r_brace => {},
                else => try p.err("expected ',' after switch prong"),
            }
        }
        _ = try p.expect(.r_brace);
    }
    return m.complete(p, .switch_expr);
}

fn switchProng(p: *Parser) Error!void {
    const m = try p.start();
    _ = try p.eat(.keyword_inline);
    const cm = try p.start();
    if (!try p.eat(.keyword_else)) {
        var items: usize = 0;
        while (true) {
            const item = try expr(p) orelse break;
            if (p.at(.ellipsis3)) {
                const rm = try item.precede(p);
                try p.bump();
                if (try expr(p) == null) try p.err("expected expression");
                _ = try rm.complete(p, .switch_item);
            }
            items += 1;
            if (!try p.eat(.comma)) break;
            if (p.at(.equal_angle_bracket_right)) break;
        }
        if (items == 0) {
            cm.abandon(p);
            if (p.events.items.len == m.index + 1) {
                m.abandon(p);
                return;
            }
            try p.err("expected switch prong");
            _ = try m.complete(p, .error_node);
            return;
        }
    }
    _ = try cm.complete(p, .switch_case);
    if (!try p.expect(.equal_angle_bracket_right) and p.atLineStart()) {
        // Items still being typed above the next prong: the next line is not this prong's body
        _ = try m.complete(p, .switch_prong);
        return;
    }
    try optPayload(p);
    if (try singleAssignExpr(p) == null) try p.err("expected expression");
    _ = try m.complete(p, .switch_prong);
}

fn asmExpr(p: *Parser) Error!CompletedMarker {
    const m = try p.start();
    try p.bump(); // asm
    _ = try p.eat(.keyword_volatile);
    _ = try p.expect(.l_paren);
    if (try expr(p) == null) try p.err("expected expression");
    if (try p.eat(.r_paren)) return m.complete(p, .asm_expr);
    _ = try p.expect(.colon);
    try asmItems(p, .asm_output);
    if (try p.eat(.colon)) {
        try asmItems(p, .asm_input);
        if (p.at(.colon)) {
            const cm = try p.start();
            try p.bump();
            if (try expr(p) == null) try p.err("expected expression");
            _ = try cm.complete(p, .asm_clobbers);
        }
    }
    _ = try p.expect(.r_paren);
    return m.complete(p, .asm_expr);
}

fn asmItems(p: *Parser, comptime kind: SyntaxKind) Error!void {
    while (p.at(.l_bracket)) {
        const m = try p.start();
        try p.bump();
        _ = try p.expect(.identifier);
        _ = try p.expect(.r_bracket);
        _ = try p.expect(.string_literal);
        _ = try p.expect(.l_paren);
        if (kind == .asm_output and !p.at(.arrow)) {
            _ = try p.expect(.identifier);
        } else {
            if (kind == .asm_output) try p.bump(); // ->
            const parsed = if (kind == .asm_output) try typeExpr(p) else try expr(p);
            if (parsed == null) try p.err("expected expression");
        }
        _ = try p.expect(.r_paren);
        _ = try m.complete(p, kind);
        switch (p.peek()) {
            .comma => try p.bump(),
            .colon, .r_paren, .r_brace, .r_bracket => break,
            else => try p.err("expected ','"),
        }
    }
}

// ── Expressions ──────────────────────────────────────────────────────

pub fn expr(p: *Parser) Error!CM {
    return exprPrec(p, 0);
}

fn binaryPrec(kind: SyntaxKind) ?u8 {
    return switch (kind) {
        .keyword_or => 10,
        .keyword_and => 20,
        .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal => 30,
        .ampersand, .caret, .pipe, .keyword_orelse, .keyword_catch => 40,
        .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_right => 50,
        .plus, .minus, .plus_plus, .plus_percent, .minus_percent, .plus_pipe, .minus_pipe => 60,
        .pipe_pipe, .asterisk, .slash, .percent, .asterisk_percent, .asterisk_pipe => 70,
        else => null,
    };
}

fn exprPrec(p: *Parser, min_prec: u8) Error!CM {
    var lhs = try prefixExpr(p) orelse return null;
    while (true) {
        const op = p.peek();
        const prec = binaryPrec(op) orelse break;
        if (prec < min_prec) break;
        const m = try lhs.precede(p);
        try p.bump();
        if (op == .keyword_catch) try optPayload(p);
        if (try exprPrec(p, prec + 1) == null) try p.err("expected expression");
        lhs = try m.complete(p, .binary_expr);
    }
    return lhs;
}

fn prefixExpr(p: *Parser) Error!CM {
    switch (p.peek()) {
        .bang, .minus, .tilde, .minus_percent, .ampersand, .keyword_try => {
            const m = try p.start();
            try p.bump();
            if (try prefixExpr(p) == null) try p.err("expected expression");
            return try m.complete(p, .prefix_expr);
        },
        else => return primaryExpr(p),
    }
}

fn primaryExpr(p: *Parser) Error!CM {
    switch (p.peek()) {
        .keyword_asm => return try asmExpr(p),
        .keyword_if => return try ifExpr(p, try p.start(), .expr),
        .keyword_break, .keyword_continue => {
            const m = try p.start();
            const kind: SyntaxKind = if (p.at(.keyword_break)) .break_expr else .continue_expr;
            try p.bump();
            try breakLabel(p);
            _ = try expr(p);
            return try m.complete(p, kind);
        },
        .keyword_comptime => return try prefixed(p, .comptime_expr),
        .keyword_nosuspend => return try prefixed(p, .nosuspend_expr),
        .keyword_resume => return try prefixed(p, .resume_expr),
        .keyword_return => {
            const m = try p.start();
            try p.bump();
            _ = try expr(p);
            return try m.complete(p, .return_expr);
        },
        .identifier => if (p.nth(1) == .colon) switch (p.nth(2)) {
            .keyword_inline, .keyword_for, .keyword_while => {
                const m = try p.start();
                try label(p);
                return try loop(p, m, .expr);
            },
            else => {},
        },
        .keyword_inline, .keyword_for, .keyword_while => return try loop(p, try p.start(), .expr),
        .l_brace => return try block(p, null),
        else => {},
    }
    return curlySuffixExpr(p);
}

fn prefixed(p: *Parser, kind: SyntaxKind) Error!CompletedMarker {
    const m = try p.start();
    try p.bump();
    if (try expr(p) == null) try p.err("expected expression");
    return m.complete(p, kind);
}

fn breakLabel(p: *Parser) Error!void {
    if (!(p.at(.colon) and p.nth(1) == .identifier)) return;
    const m = try p.start();
    try p.bump();
    try p.bump();
    _ = try m.complete(p, .break_label);
}

/// `TypeExpr InitList?`
fn curlySuffixExpr(p: *Parser) Error!CM {
    const lhs = try typeExpr(p) orelse return null;
    if (!p.at(.l_brace)) return lhs;
    const m = try lhs.precede(p);
    try initList(p);
    return try m.complete(p, .init_expr);
}

/// `{ .a = x, .b = y }` or `{ x, y }`
fn initList(p: *Parser) Error!void {
    const m = try p.start();
    try p.bump(); // {
    while (true) {
        if (try p.eat(.r_brace)) break;
        if (p.atEof() or atListEnd(p)) {
            try p.err("expected '}'");
            break;
        }
        if (p.at(.period) and p.nth(1) == .identifier and p.nth(2) == .equal) {
            const fm = try p.start();
            try p.bump();
            try p.bump();
            try p.bump();
            if (try expr(p) == null) try p.err("expected expression");
            _ = try fm.complete(p, .field_init);
        } else if (try expr(p) == null) {
            switch (p.peek()) {
                .r_paren, .r_bracket, .semicolon => {
                    try p.err("expected '}'");
                    break;
                },
                else => {
                    try p.errBump("expected initializer");
                    continue;
                },
            }
        }
        switch (p.peek()) {
            .comma => try p.bump(),
            .r_brace => {},
            .colon, .r_paren, .r_bracket => {
                try p.err("expected '}'");
                break;
            },
            else => if (!atListEnd(p)) try p.err("expected ','"),
        }
    }
    _ = try m.complete(p, .init_list);
}

fn typeExpr(p: *Parser) Error!CM {
    switch (p.peek()) {
        .question_mark => return try prefixedType(p, .optional_type, 1),
        .keyword_anyframe => if (p.nth(1) == .arrow) return try prefixedType(p, .anyframe_type, 2),
        .asterisk => {
            const m = try p.start();
            try p.bump();
            try ptrModifiers(p);
            if (try typeExpr(p) == null) try p.err("expected type expression");
            return try m.complete(p, .ptr_type);
        },
        .l_bracket => {
            const m = try p.start();
            try p.bump();
            if (try p.eat(.asterisk)) {
                // `[*]T`, `[*c]T`, `[*:s]T`
                if (p.at(.identifier) and std.mem.eql(u8, p.nthText(0), "c")) {
                    try p.bump();
                } else if (p.at(.colon)) {
                    try sentinel(p);
                }
                _ = try p.expect(.r_bracket);
                try ptrModifiers(p);
                if (try typeExpr(p) == null) try p.err("expected type expression");
                return try m.complete(p, .ptr_type);
            }
            const has_len = try expr(p) != null;
            if (p.at(.colon)) try sentinel(p);
            _ = try p.expect(.r_bracket);
            if (!has_len) try ptrModifiers(p);
            if (try typeExpr(p) == null) try p.err("expected type expression");
            return try m.complete(p, if (has_len) .array_type else .slice_type);
        },
        else => {},
    }
    return errorUnionExpr(p);
}

fn prefixedType(p: *Parser, kind: SyntaxKind, tokens: u8) Error!CompletedMarker {
    const m = try p.start();
    for (0..tokens) |_| try p.bump();
    if (try typeExpr(p) == null) try p.err("expected type expression");
    return m.complete(p, kind);
}

fn sentinel(p: *Parser) Error!void {
    const m = try p.start();
    try p.bump(); // :
    if (try expr(p) == null) try p.err("expected expression");
    _ = try m.complete(p, .sentinel);
}

fn ptrModifiers(p: *Parser) Error!void {
    while (true) switch (p.peek()) {
        .keyword_align => _ = try byteAlign(p),
        .keyword_addrspace => _ = try clause(p, .keyword_addrspace, .addrspace_clause),
        .keyword_allowzero, .keyword_const, .keyword_volatile => try p.bump(),
        else => return,
    };
}

fn errorUnionExpr(p: *Parser) Error!CM {
    const lhs = try suffixExpr(p) orelse return null;
    if (!p.at(.bang)) return lhs;
    const m = try lhs.precede(p);
    try p.bump();
    if (try typeExpr(p) == null) try p.err("expected type expression");
    return try m.complete(p, .error_union_type);
}

fn suffixExpr(p: *Parser) Error!CM {
    // A `.` without a name yet is an element being typed: what follows belongs to the next one
    const nameless_literal = p.at(.period) and switch (p.nth(1)) {
        .identifier, .l_brace => false,
        else => true,
    };
    var lhs = try primaryTypeExpr(p) orelse return null;
    if (nameless_literal) return lhs;
    while (true) {
        switch (p.peek()) {
            .l_bracket => {
                const m = try lhs.precede(p);
                try p.bump();
                if (try expr(p) == null) try p.err("expected expression");
                if (try p.eat(.ellipsis2)) {
                    _ = try expr(p);
                    if (p.at(.colon)) try sentinel(p);
                    _ = try p.expect(.r_bracket);
                    lhs = try m.complete(p, .slice_expr);
                } else {
                    _ = try p.expect(.r_bracket);
                    lhs = try m.complete(p, .index_expr);
                }
            },
            .period_asterisk => {
                const m = try lhs.precede(p);
                try p.bump();
                lhs = try m.complete(p, .deref_expr);
            },
            .period => switch (p.nth(1)) {
                .identifier => {
                    // `.na` typed above a line starting with `.name` (the next field, prong or
                    // argument): an enum literal never has fields, so the literal ends here
                    if (lhs.kind == .enum_literal and p.atLineStart()) return lhs;
                    const m = try lhs.precede(p);
                    try p.bump();
                    try p.bump();
                    lhs = try m.complete(p, .field_access);
                },
                .question_mark => {
                    const m = try lhs.precede(p);
                    try p.bump();
                    try p.bump();
                    lhs = try m.complete(p, .unwrap_optional);
                },
                .l_brace => return lhs,
                else => {
                    // `foo.` is not finished yet: keep the field access structure,
                    // which completion relies on
                    const m = try lhs.precede(p);
                    try p.bump();
                    try p.err("expected field name");
                    lhs = try m.complete(p, .field_access);
                },
            },
            .l_paren => {
                const m = try lhs.precede(p);
                try argList(p);
                lhs = try m.complete(p, .call_expr);
            },
            else => return lhs,
        }
    }
}

fn argList(p: *Parser) Error!void {
    const m = try p.start();
    try p.bump(); // (
    while (true) {
        if (try p.eat(.r_paren)) break;
        if (p.atEof() or atListEnd(p)) {
            try p.err("expected ')'");
            break;
        }
        if (try expr(p) == null) {
            switch (p.peek()) {
                .r_brace, .r_bracket, .semicolon => {
                    try p.err("expected ')'");
                    break;
                },
                else => {
                    try p.errBump("expected parameter");
                    continue;
                },
            }
        }
        switch (p.peek()) {
            .comma => try p.bump(),
            .r_paren => {},
            .colon, .r_brace, .r_bracket => {
                try p.err("expected ')'");
                break;
            },
            else => if (!atListEnd(p)) try p.err("expected ',' after parameter"),
        }
    }
    _ = try m.complete(p, .arg_list);
}

fn primaryTypeExpr(p: *Parser) Error!CM {
    switch (p.peek()) {
        .char_literal, .number_literal, .string_literal => return try single(p, .literal),
        .multiline_string_literal_line => {
            const m = try p.start();
            while (p.at(.multiline_string_literal_line)) try p.bump();
            return try m.complete(p, .literal);
        },
        .keyword_unreachable => return try single(p, .unreachable_expr),
        .keyword_anyframe => return try single(p, .anyframe_literal),
        .builtin => {
            const m = try p.start();
            try p.bump();
            if (p.at(.l_paren)) try argList(p) else try p.err("expected argument list");
            return try m.complete(p, .builtin_call);
        },
        .keyword_fn => return try fnProto(p),
        .keyword_if => return try ifExpr(p, try p.start(), .type),
        .keyword_switch => return try switchExpr(p, try p.start()),
        .keyword_extern, .keyword_packed, .keyword_struct, .keyword_opaque, .keyword_enum, .keyword_union => return try containerDecl(p),
        .keyword_comptime => return try prefixedType(p, .comptime_expr, 1),
        .identifier => {
            if (p.nth(1) == .colon) switch (p.nth(2)) {
                .keyword_inline, .keyword_for, .keyword_while => {
                    const m = try p.start();
                    try label(p);
                    return try loop(p, m, .type);
                },
                .keyword_switch => {
                    const m = try p.start();
                    try label(p);
                    return try switchExpr(p, m);
                },
                .l_brace => {
                    const m = try p.start();
                    try label(p);
                    return try block(p, m);
                },
                else => {},
            };
            return try single(p, .name_ref);
        },
        .keyword_inline, .keyword_for, .keyword_while => return try loop(p, try p.start(), .type),
        .period => switch (p.nth(1)) {
            .identifier => {
                const m = try p.start();
                try p.bump();
                try p.bump();
                return try m.complete(p, .enum_literal);
            },
            .l_brace => {
                const m = try p.start();
                try p.bump();
                try initList(p);
                return try m.complete(p, .init_expr);
            },
            // No name after `.` yet (still typing): keep it in the enclosing expression as an enum
            // literal with a missing name, so that completion can list members by expected type
            else => {
                const m = try p.start();
                try p.bump();
                _ = try p.expect(.identifier);
                return try m.complete(p, .enum_literal);
            },
        },
        .keyword_error => {
            const m = try p.start();
            try p.bump();
            if (p.at(.l_brace)) {
                try errorSetBody(p);
                return try m.complete(p, .error_set_decl);
            }
            _ = try p.expect(.period);
            _ = try p.expect(.identifier);
            return try m.complete(p, .error_value);
        },
        .l_paren => {
            const m = try p.start();
            try p.bump();
            if (try expr(p) == null) try p.err("expected expression");
            _ = try p.expect(.r_paren);
            return try m.complete(p, .paren_expr);
        },
        else => return null,
    }
}

fn single(p: *Parser, kind: SyntaxKind) Error!CompletedMarker {
    const m = try p.start();
    try p.bump();
    return m.complete(p, kind);
}

fn errorSetBody(p: *Parser) Error!void {
    try p.bump(); // {
    while (true) {
        if (try p.eat(.r_brace)) break;
        switch (p.peek()) {
            .eof, .semicolon, .r_paren, .r_bracket => {
                try p.err("expected '}'");
                break;
            },
            else => if (atListEnd(p)) {
                try p.err("expected '}'");
                break;
            },
        }
        while (p.at(.doc_comment)) try p.bump();
        if (!try p.eat(.identifier)) {
            try p.errBump("expected error name");
            continue;
        }
        switch (p.peek()) {
            .comma => try p.bump(),
            .r_brace => {},
            else => if (!atListEnd(p)) try p.err("expected ','"),
        }
    }
}

pub fn containerDecl(p: *Parser) Error!CompletedMarker {
    const m = try p.start();
    _ = try p.eat(.keyword_extern) or try p.eat(.keyword_packed);
    switch (p.peek()) {
        .keyword_struct, .keyword_enum => {
            try p.bump();
            if (try p.eat(.l_paren)) {
                if (try expr(p) == null) try p.err("expected expression");
                _ = try p.expect(.r_paren);
            }
        },
        .keyword_union => {
            try p.bump();
            if (try p.eat(.l_paren)) {
                if (try p.eat(.keyword_enum)) {
                    if (try p.eat(.l_paren)) {
                        if (try expr(p) == null) try p.err("expected expression");
                        _ = try p.expect(.r_paren);
                    }
                } else if (try expr(p) == null) try p.err("expected expression");
                _ = try p.expect(.r_paren);
            }
        },
        .keyword_opaque => try p.bump(),
        else => try p.err("expected struct, enum, union or opaque"),
    }
    if (try p.expect(.l_brace)) {
        try containerMembers(p);
        _ = try p.expect(.r_brace);
    }
    return m.complete(p, .container_decl);
}

/// Whether the current token can start a type expression (matching the branches of `typeExpr`).
fn atTypeExprStart(p: *Parser) bool {
    return switch (p.peek()) {
        .question_mark,
        .keyword_anyframe,
        .asterisk,
        .l_bracket,
        .char_literal,
        .number_literal,
        .keyword_unreachable,
        .string_literal,
        .multiline_string_literal_line,
        .builtin,
        .keyword_fn,
        .keyword_if,
        .keyword_switch,
        .keyword_extern,
        .keyword_packed,
        .keyword_struct,
        .keyword_opaque,
        .keyword_enum,
        .keyword_union,
        .keyword_comptime,
        .identifier,
        .keyword_inline,
        .keyword_for,
        .keyword_while,
        .keyword_error,
        .l_paren,
        => true,
        .period => switch (p.nth(1)) {
            .identifier, .l_brace => true,
            else => false,
        },
        else => false,
    };
}
