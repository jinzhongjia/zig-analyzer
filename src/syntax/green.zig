//! 绿树：不可变、只记录长度不记录位置，子树可在多个版本之间共享。

const std = @import("std");
const Allocator = std.mem.Allocator;
const SyntaxKind = @import("kind.zig").SyntaxKind;
const isToken = @import("kind.zig").isToken;

pub const GreenToken = struct {
    kind: SyntaxKind,
    /// 指向 `Parse.source`
    text: []const u8,
};

pub const GreenNode = struct {
    kind: SyntaxKind,
    text_len: u32,
    children: []const GreenElement,
};

/// 节点的子元素：节点或 token。压缩为 16 字节（标签联合需要 32 字节）：一个 token 一个元素，
/// 绿树的内存主要花在这里
pub const GreenElement = struct {
    /// 节点：`*const GreenNode`；token：文本起始（指向 `Parse.source`）
    ptr: [*]const u8,
    /// 节点：`text_len`；token：文本长度
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

/// 自底向上构造绿树。节点内存分配在 `arena` 上。
pub const Builder = struct {
    arena: Allocator,
    gpa: Allocator,
    /// 当前所有未闭合节点的子元素，按层级连续存放
    children: std.ArrayList(GreenElement) = .empty,
    /// 未闭合节点：种类与其子元素在 `children` 中的起始位置
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
        node.* = .{ .kind = open.kind, .text_len = len, .children = try b.arena.dupe(GreenElement, elems) };
        b.children.shrinkRetainingCapacity(open.start);
        try b.children.append(b.gpa, .initNode(node));
    }

    pub fn depth(b: *const Builder) usize {
        return b.stack.items.len;
    }

    /// 结束构造，返回根节点。
    pub fn finish(b: *Builder) *const GreenNode {
        std.debug.assert(b.stack.items.len == 0 and b.children.items.len == 1);
        return b.children.items[0].node().?;
    }
};
