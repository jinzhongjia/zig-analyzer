//! 红树：在绿树上按需计算绝对位置的轻量游标（值类型，不分配内存）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const green = @import("green.zig");
const kind_mod = @import("kind.zig");
const SyntaxKind = kind_mod.SyntaxKind;

pub const TextRange = struct {
    start: u32,
    end: u32,

    pub fn contains(r: TextRange, offset: u32) bool {
        return r.start <= offset and offset < r.end;
    }
};

pub const SyntaxToken = struct {
    kind: SyntaxKind,
    text: []const u8,
    offset: u32,

    pub fn range(t: SyntaxToken) TextRange {
        return .{ .start = t.offset, .end = t.offset + @as(u32, @intCast(t.text.len)) };
    }
};

pub const SyntaxElement = union(enum) {
    node: SyntaxNode,
    token: SyntaxToken,

    pub fn kind(e: SyntaxElement) SyntaxKind {
        return switch (e) {
            .node => |n| n.kind(),
            .token => |t| t.kind,
        };
    }

    pub fn range(e: SyntaxElement) TextRange {
        return switch (e) {
            .node => |n| n.range(),
            .token => |t| t.range(),
        };
    }
};

pub const SyntaxNode = struct {
    green: *const green.GreenNode,
    offset: u32,

    pub fn kind(n: SyntaxNode) SyntaxKind {
        return n.green.kind;
    }

    pub fn range(n: SyntaxNode) TextRange {
        return .{ .start = n.offset, .end = n.offset + n.green.text_len };
    }

    pub fn text(n: SyntaxNode, source: []const u8) []const u8 {
        const r = n.range();
        return source[r.start..r.end];
    }

    pub fn children(n: SyntaxNode) Children {
        return .{ .elems = n.green.children, .offset = n.offset };
    }

    pub const Children = struct {
        elems: []const green.GreenElement,
        offset: u32,
        index: usize = 0,

        pub fn next(it: *Children) ?SyntaxElement {
            if (it.index >= it.elems.len) return null;
            const e = it.elems[it.index];
            it.index += 1;
            const off = it.offset;
            it.offset += e.textLen();
            return switch (e.unpack()) {
                .node => |g| .{ .node = .{ .green = g, .offset = off } },
                .token => |t| .{ .token = .{ .kind = t.kind, .text = t.text, .offset = off } },
            };
        }

        pub fn nextNode(it: *Children) ?SyntaxNode {
            while (it.next()) |e| if (e == .node) return e.node;
            return null;
        }
    };

    /// 第一个指定种类的直接子节点
    pub fn childNode(n: SyntaxNode, k: SyntaxKind) ?SyntaxNode {
        var it = n.children();
        while (it.nextNode()) |c| if (c.kind() == k) return c;
        return null;
    }

    /// 第一个指定种类的直接子 token
    pub fn childToken(n: SyntaxNode, k: SyntaxKind) ?SyntaxToken {
        var it = n.children();
        while (it.next()) |e| if (e == .token and e.token.kind == k) return e.token;
        return null;
    }

    pub fn firstToken(n: SyntaxNode) ?SyntaxToken {
        var it = n.children();
        while (it.next()) |e| switch (e) {
            .token => |t| return t,
            .node => |c| if (c.firstToken()) |t| return t,
        };
        return null;
    }

    /// 包含 `offset` 的最深 token。`offset` 落在两个 token 的边界上时取右侧 token；
    /// 等于文本末尾时取最后一个 token。
    pub fn tokenAtOffset(n: SyntaxNode, offset: u32) ?SyntaxToken {
        var node = n;
        outer: while (true) {
            var it = node.children();
            var last: ?SyntaxElement = null;
            while (it.next()) |e| {
                last = e;
                if (!e.range().contains(offset)) continue;
                switch (e) {
                    .token => |t| return t,
                    .node => |c| {
                        node = c;
                        continue :outer;
                    },
                }
            }
            // offset == 文本末尾
            const tail = last orelse return null;
            if (offset != tail.range().end) return null;
            switch (tail) {
                .token => |t| return t,
                .node => |c| node = c,
            }
        }
    }

    /// 从根到覆盖 `offset` 的最深节点的路径（含两端）。
    pub fn coveringPath(n: SyntaxNode, gpa: Allocator, offset: u32) Allocator.Error![]SyntaxNode {
        var path: std.ArrayList(SyntaxNode) = .empty;
        errdefer path.deinit(gpa);
        try path.append(gpa, n);
        var node = n;
        outer: while (true) {
            var it = node.children();
            while (it.nextNode()) |c| {
                if (c.range().contains(offset)) {
                    try path.append(gpa, c);
                    node = c;
                    continue :outer;
                }
            }
            break;
        }
        return path.toOwnedSlice(gpa);
    }

    /// 以缩进树的形式输出，用于测试快照与调试。
    pub fn dump(n: SyntaxNode, w: *std.Io.Writer, opts: DumpOptions) std.Io.Writer.Error!void {
        try dumpRec(n, w, opts, 0);
    }

    pub const DumpOptions = struct {
        trivia: bool = false,
    };

    fn dumpRec(n: SyntaxNode, w: *std.Io.Writer, opts: DumpOptions, depth: usize) std.Io.Writer.Error!void {
        try w.splatByteAll(' ', depth * 2);
        try w.print("{t}@{d}..{d}\n", .{ n.kind(), n.range().start, n.range().end });
        var it = n.children();
        while (it.next()) |e| switch (e) {
            .node => |c| try dumpRec(c, w, opts, depth + 1),
            .token => |t| {
                if (!opts.trivia and kind_mod.isTrivia(t.kind)) continue;
                try w.splatByteAll(' ', (depth + 1) * 2);
                try w.print("{t} \"{f}\"\n", .{ t.kind, std.zig.fmtString(t.text) });
            },
        };
    }
};
