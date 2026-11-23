//! Green tree: immutable, records only lengths and no positions; subtrees can be shared
//! between versions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SyntaxKind = @import("kind.zig").SyntaxKind;
const isToken = @import("kind.zig").isToken;

pub const GreenToken = struct {
    kind: SyntaxKind,
    /// Points into `Parse.source`
    text: []const u8,
};

pub const GreenNode = struct {
    kind: SyntaxKind,
    /// Summary bits of the whole subtree; they take padding that the node already has, so they do
    /// not enlarge it
    flags: Flags,
    text_len: u32,
    children: []const GreenElement,

    /// What the subtree contains (the node itself included), so that a walk looking for a
    /// container or an import can skip a subtree whose bit is clear
    pub const Flags = packed struct(u8) {
        /// A `container_decl` node
        has_container: bool = false,
        /// An `@import` builtin call
        has_import: bool = false,
        padding: u6 = 0,
    };

    comptime {
        std.debug.assert(@sizeOf(GreenNode) == 24);
    }

    /// The flags of a node with `kind` and `children`: the child nodes carry those of their own
    /// subtrees
    pub fn flagsOf(kind: SyntaxKind, children: []const GreenElement) Flags {
        var f: Flags = .{ .has_container = kind == .container_decl };
        for (children) |e| {
            if (e.node()) |n| {
                f.has_container = f.has_container or n.flags.has_container;
                f.has_import = f.has_import or n.flags.has_import;
            } else {
                // The name of a builtin call is a `.builtin` token of that node
                const t = e.unpack().token;
                if (kind == .builtin_call and t.kind == .builtin and std.mem.eql(u8, t.text, "@import")) f.has_import = true;
            }
        }
        return f;
    }
};

/// Child element of a node: a node or a token. Packed into 16 bytes (a tagged union would need
/// 32): one element per token, and most of the green tree's memory goes here
pub const GreenElement = struct {
    /// Node: `*const GreenNode`; token: start of the text (points into `Parse.source`)
    ptr: [*]const u8,
    /// Node: `text_len`; token: text length
    len: u32,
    syntax_kind: SyntaxKind,
    is_node: bool,

    comptime {
        std.debug.assert(@sizeOf(GreenElement) == 16);
    }

    pub const Unpacked = union(enum) {
        node: *const GreenNode,
        token: GreenToken,
    };

    pub fn initNode(n: *const GreenNode) GreenElement {
        return .{ .ptr = @ptrCast(n), .len = n.text_len, .syntax_kind = n.kind, .is_node = true };
    }

    pub fn initToken(k: SyntaxKind, text: []const u8) GreenElement {
        return .{ .ptr = text.ptr, .len = @intCast(text.len), .syntax_kind = k, .is_node = false };
    }

    pub fn unpack(e: GreenElement) Unpacked {
        if (e.is_node) return .{ .node = @ptrCast(@alignCast(e.ptr)) };
        return .{ .token = .{ .kind = e.syntax_kind, .text = e.ptr[0..e.len] } };
    }

    pub fn node(e: GreenElement) ?*const GreenNode {
        return if (e.is_node) @ptrCast(@alignCast(e.ptr)) else null;
    }

    pub fn kind(e: GreenElement) SyntaxKind {
        return e.syntax_kind;
    }

    pub fn textLen(e: GreenElement) u32 {
        return e.len;
    }
};

/// Builds a green tree bottom-up. Node memory is allocated in `arena`.
pub const Builder = struct {
    arena: Allocator,
    gpa: Allocator,
    /// Children of all currently open nodes, stored contiguously level by level
    children: std.ArrayList(GreenElement) = .empty,
    /// Open nodes: the kind and the start of their children in `children`
    stack: std.ArrayList(struct { kind: SyntaxKind, start: usize }) = .empty,

    pub fn deinit(b: *Builder) void {
        b.children.deinit(b.gpa);
        b.stack.deinit(b.gpa);
    }

    pub fn startNode(b: *Builder, kind: SyntaxKind) Allocator.Error!void {
        std.debug.assert(!isToken(kind));
        try b.stack.append(b.gpa, .{ .kind = kind, .start = b.children.items.len });
    }

    pub fn token(b: *Builder, kind: SyntaxKind, text: []const u8) Allocator.Error!void {
        try b.children.append(b.gpa, .initToken(kind, text));
    }

    pub fn finishNode(b: *Builder) Allocator.Error!void {
        const open = b.stack.pop().?;
        const elems = b.children.items[open.start..];
        var len: u32 = 0;
        for (elems) |e| len += e.textLen();
        const node = try b.arena.create(GreenNode);
        node.* = .{
            .kind = open.kind,
            .flags = GreenNode.flagsOf(open.kind, elems),
            .text_len = len,
            .children = try b.arena.dupe(GreenElement, elems),
        };
        b.children.shrinkRetainingCapacity(open.start);
        try b.children.append(b.gpa, .initNode(node));
    }

    pub fn depth(b: *const Builder) usize {
        return b.stack.items.len;
    }

    /// Finishes building and returns the root node.
    pub fn finish(b: *Builder) *const GreenNode {
        std.debug.assert(b.stack.items.len == 0 and b.children.items.len == 1);
        return b.children.items[0].node().?;
    }
};
