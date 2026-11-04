//! Event-based parser core.
//!
//! Grammar functions (grammar.zig) only emit events: start node, consume token, finish node;
//! they never build the tree directly. This lets "parse the left operand first, then discover
//! it is part of a binary expression" wrap a parent node around it afterwards via
//! `CompletedMarker.precede`, without backtracking. `buildTree` finally converts the events
//! into a green tree and attaches trivia.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const kind_mod = @import("kind.zig");
const SyntaxKind = kind_mod.SyntaxKind;
const lexer = @import("lexer.zig");
const green = @import("green.zig");

pub const Event = union(enum) {
    start: struct {
        /// null means abandoned (tombstone)
        kind: ?SyntaxKind,
        /// Nonzero when a parent node was wrapped around this node afterwards: the parent's
        /// start event is at `this event's index + forward_parent`
        forward_parent: u32 = 0,
    },
    finish,
    /// Consumes the next non-trivia token
    token,
};

pub const Error = struct {
    /// Byte offset where the error occurred
    offset: u32,
    message: []const u8,
};

pub const Parser = struct {
    gpa: Allocator,
    source: []const u8,
    tokens: []const lexer.Token,
    /// Indices of the non-trivia tokens in `tokens`
    significant: []const u32,
    /// Doc comments on the variadic marker `...` are accepted (see `Parse.Dialect`)
    variadic_doc_comments: bool = false,
    pos: u32 = 0,
    events: std.ArrayList(Event) = .empty,
    errors: std.ArrayList(Error) = .empty,
    /// Maximum number of token peeks between two token consumptions: keeps grammar functions
    /// from looping forever without consuming tokens
    fuel: u32 = max_fuel,

    /// When nested constructs unwind level by level at an error, each level peeks at tokens
    /// without consuming them, so the limit must be far above the product of the nesting depth
    /// and the peeks per level
    const max_fuel = 1 << 24;

    pub fn deinit(p: *Parser) void {
        p.events.deinit(p.gpa);
        p.errors.deinit(p.gpa);
    }

    // ── Peeking at tokens ───────────────────────────────────────────────

    /// Kind of the n-th not yet consumed non-trivia token; eof when out of range.
    pub fn nth(p: *Parser, n: u32) SyntaxKind {
        if (p.fuel == 0) std.debug.panic("parser stuck at offset {d}", .{p.currentOffset()});
        p.fuel -= 1;
        const i = p.pos + n;
        if (i >= p.significant.len) return .eof;
        const token = p.tokens[p.significant[i]];
        // An unterminated quoted identifier still occupies the name position; keep the original
        // invalid token and let the grammar decide whether it is a reference, a declaration, etc.
        if (token.kind == .invalid and std.mem.startsWith(u8, token.text(p.source), "@\"")) return .identifier;
        return token.kind;
    }

    pub fn peek(p: *Parser) SyntaxKind {
        return p.nth(0);
    }

    pub fn at(p: *Parser, kind: SyntaxKind) bool {
        return p.peek() == kind;
    }

    pub fn atAny(p: *Parser, kinds: []const SyntaxKind) bool {
        const k = p.peek();
        for (kinds) |candidate| if (k == candidate) return true;
        return false;
    }

    pub fn nthText(p: *Parser, n: u32) []const u8 {
        const i = p.pos + n;
        if (i >= p.significant.len) return "";
        return p.tokens[p.significant[i]].text(p.source);
    }

    pub fn atEof(p: *Parser) bool {
        return p.pos >= p.significant.len;
    }

    pub fn currentOffset(p: *const Parser) u32 {
        if (p.pos >= p.significant.len) return @intCast(p.source.len);
        return p.tokens[p.significant[p.pos]].start;
    }

    /// Whether a line break separates the current token from the previous significant token
    pub fn atLineStart(p: *const Parser) bool {
        if (p.pos >= p.significant.len) return false;
        var i: u32 = if (p.pos == 0) 0 else p.significant[p.pos - 1] + 1;
        while (i < p.significant[p.pos]) : (i += 1) {
            if (std.mem.indexOfScalar(u8, p.tokens[i].text(p.source), '\n') != null) return true;
        }
        return false;
    }

    // ── Consuming tokens ────────────────────────────────────────────────

    pub fn bump(p: *Parser) Allocator.Error!void {
        assert(!p.atEof());
        const token = p.tokens[p.significant[p.pos]];
        if (token.kind == .invalid and std.mem.startsWith(u8, token.text(p.source), "@\""))
            try p.err("invalid identifier");
        p.pos += 1;
        p.fuel = max_fuel;
        try p.events.append(p.gpa, .token);
    }

    pub fn eat(p: *Parser, kind: SyntaxKind) Allocator.Error!bool {
        if (!p.at(kind)) return false;
        try p.bump();
        return true;
    }

    /// Expects the current token to be `kind`; otherwise records an error but consumes no token.
    pub fn expect(p: *Parser, comptime kind: SyntaxKind) Allocator.Error!bool {
        if (try p.eat(kind)) return true;
        try p.err(comptime expectedMessage(kind));
        return false;
    }

    pub fn err(p: *Parser, message: []const u8) Allocator.Error!void {
        try p.errors.append(p.gpa, .{ .offset = p.currentOffset(), .message = message });
    }

    /// Records an error and wraps the current token in an `error_node` (guaranteeing progress).
    pub fn errBump(p: *Parser, message: []const u8) Allocator.Error!void {
        try p.err(message);
        if (p.atEof()) return;
        const m = try p.start();
        try p.bump();
        _ = try m.complete(p, .error_node);
    }

    // ── Marker ──────────────────────────────────────────────────────────

    pub fn start(p: *Parser) Allocator.Error!Marker {
        const index: u32 = @intCast(p.events.items.len);
        try p.events.append(p.gpa, .{ .start = .{ .kind = null } });
        return .{ .index = index };
    }
};

pub const Marker = struct {
    index: u32,

    pub fn complete(m: Marker, p: *Parser, kind: SyntaxKind) Allocator.Error!CompletedMarker {
        p.events.items[m.index].start.kind = kind;
        try p.events.append(p.gpa, .finish);
        return .{ .index = m.index, .kind = kind };
    }

    /// Abandons this node: the child events already produced are kept and become direct children
    /// of the enclosing node.
    pub fn abandon(m: Marker, p: *Parser) void {
        if (m.index == p.events.items.len - 1) {
            _ = p.events.pop();
        } else {
            p.events.items[m.index] = .{ .start = .{ .kind = null } };
        }
    }
};

pub const CompletedMarker = struct {
    index: u32,
    kind: SyntaxKind,

    /// Wraps a new parent node around the completed node (returns the parent's Marker).
    pub fn precede(cm: CompletedMarker, p: *Parser) Allocator.Error!Marker {
        const parent = try p.start();
        p.events.items[cm.index].start.forward_parent = parent.index - cm.index;
        return parent;
    }
};

/// Converts events into a green tree. Trivia rule: trivia before the start of a node is
/// attached to the parent, so a node always starts with a significant token; trivia at the
/// end of the file is attached to the root node.
pub fn buildTree(
    builder: *green.Builder,
    source: []const u8,
    tokens: []const lexer.Token,
    events: []Event,
) Allocator.Error!void {
    var cursor: usize = 0;
    var parents: std.ArrayList(SyntaxKind) = .empty;
    defer parents.deinit(builder.gpa);

    for (events, 0..) |*event, i| switch (event.*) {
        .start => |s| {
            const kind = s.kind orelse continue;
            // Collect the forward_parent chain: the outermost parent is opened first
            parents.clearRetainingCapacity();
            try parents.append(builder.gpa, kind);
            var idx = i;
            var fp = s.forward_parent;
            while (fp != 0) {
                idx += fp;
                const parent = &events[idx].start;
                try parents.append(builder.gpa, parent.kind.?);
                fp = parent.forward_parent;
                parent.* = .{ .kind = null };
            }
            if (builder.depth() > 0) cursor = try emitTrivia(builder, source, tokens, cursor);
            var j = parents.items.len;
            while (j > 0) {
                j -= 1;
                try builder.startNode(parents.items[j]);
            }
        },
        .finish => {
            if (builder.depth() == 1) {
                // Before closing the root node, attach all remaining tokens (necessarily trivia)
                while (cursor < tokens.len) : (cursor += 1) {
                    const t = tokens[cursor];
                    try builder.token(t.kind, t.text(source));
                }
            }
            try builder.finishNode();
        },
        .token => {
            cursor = try emitTrivia(builder, source, tokens, cursor);
            const t = tokens[cursor];
            assert(!kind_mod.isTrivia(t.kind));
            try builder.token(t.kind, t.text(source));
            cursor += 1;
        },
    };
}

fn emitTrivia(builder: *green.Builder, source: []const u8, tokens: []const lexer.Token, start: usize) Allocator.Error!usize {
    var cursor = start;
    while (cursor < tokens.len and kind_mod.isTrivia(tokens[cursor].kind)) : (cursor += 1) {
        try builder.token(tokens[cursor].kind, tokens[cursor].text(source));
    }
    return cursor;
}

fn expectedMessage(comptime kind: SyntaxKind) []const u8 {
    const lexeme = if (kind_mod.toTokenTag(kind)) |tag| tag.lexeme() else null;
    return if (lexeme) |l| "expected '" ++ l ++ "'" else "expected " ++ @tagName(kind);
}
