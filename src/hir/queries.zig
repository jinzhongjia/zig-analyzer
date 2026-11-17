//! HIR queries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const syntax = @import("../syntax/queries.zig");
const ast = @import("../syntax/ast.zig");
const Body = @import("Body.zig");
const lower_mod = @import("lower.zig");
const lower = lower_mod.lower;
const mem = @import("../util/mem.zig");

/// How the member node `node` is lowered: the root expression of a ZON file (kind `zon`) as an
/// expression, enum members and union fields written as just a name without that name, and other
/// members (including containers defined inside the root expression of a ZON file) as members
fn ownerOf(ctx: anytype, key: OwnerKey, node: ast.SyntaxNode) engine.Error!lower_mod.Owner {
    const tree = try ctx.get(syntax.FileItemTree, key.file);
    const it = tree.items[tree.itemOf(key.item) orelse return .member];
    if (it.kind == .zon) return .zon;
    return if (fieldIsName(tree, it, node)) .bare_field else .member;
}

/// Enum members and union fields written as just a name (no `:`): the type expression position
/// holds the name. Fields of tuple-like structs have no `:` either, but there it is a type, so
/// the kind of the enclosing container must come from the ItemTree
fn fieldIsName(tree: *const ItemTree, it: ItemTree.Item, node: ast.SyntaxNode) bool {
    if (node.kind() != .container_field or (ast.ContainerField{ .syntax = node }).name() != null) return false;
    const kind = tree.containers[it.container].kind;
    return kind == .@"enum" or kind == .@"union";
}

/// BodyOwner: a container member in a file (identified by its stable AstId)
pub const OwnerKey = struct {
    file: Vfs.FileId,
    item: ItemTree.AstId,
};

/// The syntax a member's Body is lowered from, without its position: a hash of the member's
/// text and how it is lowered. Any edit in a file changes `FileAstIdMap` (compared by pointer and
/// holding absolute positions), so this query runs for every member after each edit; it is cheap,
/// and an unchanged member keeps its value, so its `ItemBody` (in memory or evicted) is not
/// lowered again.
pub const ItemSyntax = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = OwnerKey;
    pub const Value = Source;

    pub const Source = struct {
        /// Wyhash of the text of the member node under two seeds (of the root node when
        /// the member is not found)
        hash: [2]u64,
        len: u32,
        owner: lower_mod.Owner,
    };

    pub fn compute(ctx: anytype, key: Key) engine.Error!Value {
        const parse = try ctx.get(syntax.ParseFile, key.file);
        const found = (try ctx.get(syntax.FileAstIdMap, key.file)).get(key.item);
        const node = found orelse parse.rootNode();
        const text = node.text(parse.source);
        return .{
            .hash = .{ std.hash.Wyhash.hash(0, text), std.hash.Wyhash.hash(0x9e3779b97f4a7c15, text) },
            .len = @intCast(text.len),
            .owner = if (found != null) try ownerOf(ctx, key, node) else .member,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.hash[0] == b.hash[0] and a.hash[1] == b.hash[1] and a.len == b.len and a.owner == b.owner;
    }
};

/// HIR of a member. When the contents of the Body (positions relative to the owner) are
/// unchanged, it counts as unchanged and downstream queries are not recomputed
pub const ItemBody = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = OwnerKey;
    pub const Value = *const Body;
    /// Bounds memory in long sessions: an evicted Body is lowered again on demand
    pub const lru = 16 * 1024;
    /// Value sizes vary widely (the HIR / inference result of a long function can reach
    /// hundreds of KB), so the cache is also bounded by bytes
    pub const lru_bytes = 48 * 1024 * 1024;

    pub fn bytes(v: Value) usize {
        return @sizeOf(Owned) + mem.arenaBytes(v.arena);
    }

    const Owned = struct {
        body: Body,
        source: ItemSyntax.Source,

        fn of(v: Value) *Owned {
            return @alignCast(@fieldParentPtr("body", @constCast(v)));
        }
    };

    /// Lowering reads only the member's own syntax tree, and positions in the Body are relative to
    /// the start of the member, so the Body is determined by `ItemSyntax`: that is the only
    /// recorded dependency, and the node itself is located through an untracked read of
    /// `FileAstIdMap`. When the member is not found (it was deleted), the root node is lowered as
    /// a member: it is not a member, so the Body is empty
    pub fn compute(ctx: anytype, key: Key) engine.Error!Value {
        const source = try ctx.get(ItemSyntax, key);
        const parse = try ctx.getUntracked(syntax.ParseFile, key.file);
        const node = (try ctx.getUntracked(syntax.FileAstIdMap, key.file)).get(key.item) orelse parse.rootNode();
        const gpa = ctx.db.gpa;
        const result = try gpa.create(Owned);
        errdefer gpa.destroy(result);
        result.* = .{ .body = try lower(gpa, node, source.owner), .source = source };
        return &result.body;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b or a.eql(b);
    }

    /// What the Body is lowered from (see `ItemSyntax`): when the member's text changes and then
    /// changes back while the Body is evicted, the recomputed Body keeps its changed_at
    pub fn fingerprint(v: Value) u128 {
        const s = Owned.of(v).source;
        var h: std.crypto.auth.siphash.SipHash128(1, 3) = .init(&@splat(0));
        h.update(std.mem.sliceAsBytes(&s.hash));
        h.update(std.mem.asBytes(&s.len));
        h.update(&.{@as(u8, @backingInt(s.owner))});
        return h.finalInt();
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const o = Owned.of(v.*);
        o.body.deinit(gpa);
        gpa.destroy(o);
    }
};

/// Form of a parameter: whether it has a type annotation (`anytype`) and whether it is comptime
pub const ParamForm = enum(u8) { typed, comptime_typed, any, comptime_any };

/// Forms of the parameters of a member (function). Call sites use them to decide whether a call
/// is generic: editing only the function body leaves the value unchanged, so callers are not
/// recomputed (with a direct dependency on `ItemBody`, editing the body of the callee would
/// invalidate all of its callers)
pub const ParamForms = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = OwnerKey;
    pub const Value = []const ParamForm;

    pub fn compute(ctx: anytype, key: Key) engine.Error!Value {
        const body = try ctx.get(ItemBody, key);
        const forms = try ctx.db.gpa.alloc(ParamForm, body.params.len);
        for (body.params, forms) |p, *f| {
            const b = body.binding(p);
            f.* = if (b.ty == null)
                (if (b.is_comptime) .comptime_any else .any)
            else if (b.is_comptime) .comptime_typed else .typed;
        }
        return forms;
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(ParamForm, a, b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};
