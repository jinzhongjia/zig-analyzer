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

pub const GreenElement = union(enum) {
    node: *const GreenNode,
    token: GreenToken,

    pub fn kind(e: GreenElement) SyntaxKind {
        return switch (e) {
            .node => |n| n.kind,
            .token => |t| t.kind,
        };
    }

    pub fn textLen(e: GreenElement) u32 {
        return switch (e) {
            .node => |n| n.text_len,
            .token => |t| @intCast(t.text.len),
        };
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
        try b.children.append(b.gpa, .{ .token = .{ .kind = kind, .text = text } });
    }

    pub fn finishNode(b: *Builder) Allocator.Error!void {
        const open = b.stack.pop().?;
        const elems = b.children.items[open.start..];
        var len: u32 = 0;
        for (elems) |e| len += e.textLen();
        const node = try b.arena.create(GreenNode);
        node.* = .{ .kind = open.kind, .text_len = len, .children = try b.arena.dupe(GreenElement, elems) };
        b.children.shrinkRetainingCapacity(open.start);
        try b.children.append(b.gpa, .{ .node = node });
    }

    pub fn depth(b: *const Builder) usize {
        return b.stack.items.len;
    }

    /// 结束构造，返回根节点。
    pub fn finish(b: *Builder) *const GreenNode {
        std.debug.assert(b.stack.items.len == 0 and b.children.items.len == 1);
        return b.children.items[0].node;
    }
};
