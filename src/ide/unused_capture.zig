//! Quick fix for an unused capture (AstGen's `unused capture` and `unused switch tag capture`):
//! removes the capture, or renames it to `_`. Only rewrites that keep the meaning are offered;
//! which captures can be removed and which can be renamed to `_` follows the rules of AstGen:
//! - An optional `if` / `while` (without `else |err|`): the capture is removed and the condition
//!   is compared with null (`if (x) |v|` → `if (x != null)`)
//! - `catch |err|`: the capture is removed (`catch |_|` is an error)
//! - A switch prong with only the payload capture: the whole capture is removed (`|_|` is an
//!   error); with a tag capture as well, the payload is renamed to `_`. The tag capture is removed
//!   together with its comma (`|p, _|` is an error), or the whole capture when the payload is `_`
//! - An unbounded for counter (`0..`) is removed together with its input (discarding an unbounded
//!   counter is an error). Removing the input also removes the evaluation of its start, so the
//!   start may only be a literal, a name, or a field access on a name; when it contains a name,
//!   AstGen confirms that there are no new errors, matched by position and message (a name used
//!   only there is no longer used, which can be another `unused capture`). At least one remaining
//!   input must be bounded
//! - Other captures (both captures of an error union `if` / `while`, the other captures of a for)
//!   are renamed to `_`, a pointer capture together with its `*` (`|*_|` is an error). The payload
//!   capture of an error union is not removed: without it, the payload type must be void; nor is
//!   `else |err|`: without it, the `if` becomes an optional `if`

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const ast = @import("../syntax/ast.zig");
const SyntaxNode = ast.SyntaxNode;
const SyntaxToken = ast.SyntaxToken;
const TextRange = @import("../syntax/tree.zig").TextRange;
const FileId = @import("../base/Vfs.zig").FileId;
const Edit = @import("code_actions.zig").Edit;
const rename = @import("rename.zig");
const remove_param = @import("remove_param.zig");

pub const Fix = struct {
    /// The capture is removed; otherwise it is renamed to `_`
    removed: bool,
    /// Sorted by position, non-overlapping
    edits: []const Edit,
    /// When the payload capture of a switch prong is renamed to `_`: the position of the tag
    /// capture after it. Removing that tag capture as well would leave `|_|`, which is an error
    tag: ?u32 = null,
};

/// The fix for the unused capture whose name is at `offset`; null when no rewrite is known to keep
/// the meaning
pub fn fix(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Fix {
    const arena = r.arena;
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const path = try root.coveringPath(arena, offset);
    if (path.len < 3) return null;
    const payload = path[path.len - 1];
    if (payload.kind() != .payload) return null;
    const captures = try bindings(arena, payload);
    const index = for (captures, 0..) |c, i| {
        if (c.name.offset == offset) break i;
    } else return null;
    const parent = path[path.len - 2];
    switch (parent.kind()) {
        .if_expr, .while_expr => {
            if (captures.len != 1) return null;
            // With `else |err|`, the condition is an error union
            const else_payload = if (parent.childNode(.else_clause)) |e| e.childNode(.payload) else null;
            if (else_payload != null) return try discard(arena, captures[index]);
            return try compareNull(arena, text, parent, payload);
        },
        .else_clause => switch (path[path.len - 3].kind()) {
            .if_expr, .while_expr => return try discard(arena, captures[index]),
            else => return null,
        },
        .binary_expr => {
            const op = (ast.BinaryExpr{ .syntax = parent }).op() orelse return null;
            if (op.kind != .keyword_catch) return null;
            return try remove(arena, text, payload);
        },
        .switch_prong => switch (index) {
            0 => {
                if (captures.len == 1) return try remove(arena, text, payload);
                var f = try discard(arena, captures[0]);
                f.tag = captures[1].name.offset;
                return f;
            },
            1 => {
                if (std.mem.eql(u8, captures[0].name.text, "_")) return try remove(arena, text, payload);
                return .{ .removed = true, .edits = try arena.dupe(Edit, &.{removeCapture(captures, 1)}) };
            },
            else => return null,
        },
        .for_expr => return forCapture(r, file, text, parent, captures, index),
        else => return null,
    }
}

/// A name in a capture
const Capture = struct {
    /// Start: the `*` of a pointer capture, otherwise the name
    start: u32,
    name: SyntaxToken,
};

fn bindings(arena: Allocator, payload: SyntaxNode) Allocator.Error![]const Capture {
    var out: std.ArrayList(Capture) = .empty;
    var star: ?u32 = null;
    var it = payload.children();
    while (it.next()) |e| {
        if (e != .token) continue;
        switch (e.token.kind) {
            .asterisk => star = e.token.offset,
            .identifier => {
                try out.append(arena, .{ .start = star orelse e.token.offset, .name = e.token });
                star = null;
            },
            else => {},
        }
    }
    return out.items;
}

/// Renames the capture to `_`
fn discard(arena: Allocator, c: Capture) Allocator.Error!Fix {
    return .{ .removed = false, .edits = try arena.dupe(Edit, &.{.{ .start = c.start, .end = c.name.range().end, .text = "_" }}) };
}

/// Removes the whole capture `|...|`
fn remove(arena: Allocator, text: []const u8, payload: SyntaxNode) Allocator.Error!Fix {
    return .{ .removed = true, .edits = try arena.dupe(Edit, &.{deletion(text, payload.range())}) };
}

/// Deletes `range` together with the spaces on one side: the spaces before it when something else
/// precedes it on the same line, otherwise (at the start of a line) the spaces after it
fn deletion(text: []const u8, range: TextRange) Edit {
    var start = range.start;
    while (start > 0 and (text[start - 1] == ' ' or text[start - 1] == '\t')) start -= 1;
    if (start > 0 and text[start - 1] != '\n') return .{ .start = start, .end = range.end, .text = "" };
    var end = range.end;
    while (end < text.len and (text[end] == ' ' or text[end] == '\t')) end += 1;
    return .{ .start = range.start, .end = end, .text = "" };
}

/// Removes the name at `index` together with one comma: the comma before it, or the comma after it
/// when it is the first name
fn removeCapture(captures: []const Capture, index: usize) Edit {
    const c = captures[index];
    if (index > 0) return .{ .start = captures[index - 1].name.range().end, .end = c.name.range().end, .text = "" };
    return .{ .start = c.start, .end = captures[1].start, .text = "" };
}

/// An optional `if` / `while`: removes the capture `payload` and changes the condition `x` to
/// `x != null`
fn compareNull(arena: Allocator, text: []const u8, node: SyntaxNode, payload: SyntaxNode) Allocator.Error!?Fix {
    const cond = (if (node.kind() == .if_expr) (ast.IfExpr{ .syntax = node }).cond() else (ast.WhileExpr{ .syntax = node }).cond()) orelse return null;
    const range = cond.range();
    const del = deletion(text, payload.range());
    const edits = if (needsParens(cond)) try arena.dupe(Edit, &.{
        .{ .start = range.start, .end = range.start, .text = "(" },
        .{ .start = range.end, .end = range.end, .text = ") != null" },
        del,
    }) else try arena.dupe(Edit, &.{
        .{ .start = range.end, .end = range.end, .text = " != null" },
        del,
    });
    return .{ .removed = true, .edits = edits };
}

/// Whether the expression needs parentheses before ` != null` is appended to it. Suffix and primary
/// expressions bind the tightest and do not end with an expression, so the appended comparison
/// leaves them intact; others may be operations of lower precedence (`a orelse b`), or end with an
/// expression that would take the comparison into it (`try f()`, `comptime x`)
fn needsParens(e: SyntaxNode) bool {
    return switch (e.kind()) {
        .name_ref,
        .literal,
        .builtin_call,
        .call_expr,
        .field_access,
        .index_expr,
        .slice_expr,
        .deref_expr,
        .unwrap_optional,
        .paren_expr,
        .enum_literal,
        .error_value,
        .init_expr,
        => false,
        else => true,
    };
}

/// The capture at `index` of a for, which corresponds to the input at `index`
fn forCapture(r: *Resolver, file: FileId, text: []const u8, node: SyntaxNode, captures: []const Capture, index: usize) resolve.Error!?Fix {
    const arena = r.arena;
    var inputs: std.ArrayList(SyntaxNode) = .empty;
    var it = (ast.ForExpr{ .syntax = node }).inputs();
    while (it.next()) |n| try inputs.append(arena, n);
    if (inputs.items.len != captures.len) return null;
    if (!unbounded(inputs.items[index])) return try discard(arena, captures[index]);
    const start = firstChild(inputs.items[index]) orelse return null;
    if (!plain(start)) return null;
    for (inputs.items, 0..) |x, i| {
        if (i != index and !unbounded(x)) break;
    } else return null;
    const list = node.childNode(.for_inputs) orelse return null;
    const input = try remove_param.removeItem(arena, text, list, @intCast(index)) orelse return null;
    const edits = try arena.dupe(Edit, &.{
        .{ .start = input.start, .end = input.end, .text = input.text },
        removeCapture(captures, index),
    });
    if (start.kind() != .literal) {
        const checked = try arena.alloc(rename.Edit, edits.len);
        for (edits, checked) |e, *c| c.* = .{ .start = e.start, .end = e.end, .text = e.text };
        const errors = try rename.astGenErrors(r, file, checked);
        if ((try rename.newAstGenErrors(arena, errors.before, errors.after)).len > 0) return null;
    }
    return .{ .removed = true, .edits = edits };
}

/// A range without an end, `a..`
fn unbounded(input: SyntaxNode) bool {
    if (input.kind() != .for_input) return false;
    var it = input.children();
    var dots = false;
    while (it.next()) |e| switch (e) {
        .token => |t| if (t.kind == .ellipsis2) {
            dots = true;
        },
        .node => if (dots) return false,
    };
    return dots;
}

/// An expression whose evaluation has no side effects: a literal, a name, or a field access on a
/// name, possibly parenthesized
fn plain(e: SyntaxNode) bool {
    return switch (e.kind()) {
        .literal, .name_ref => true,
        .field_access => if ((ast.FieldAccess{ .syntax = e }).lhs()) |lhs| plain(lhs) else false,
        .paren_expr => if (firstChild(e)) |inner| plain(inner) else false,
        else => false,
    };
}

fn firstChild(n: SyntaxNode) ?SyntaxNode {
    var it = n.children();
    return it.nextNode();
}
