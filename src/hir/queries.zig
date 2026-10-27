//! HIR queries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const syntax = @import("../syntax/queries.zig");
const ast = @import("../syntax/ast.zig");
const Parse = @import("../syntax/Parse.zig");
const Body = @import("Body.zig");
const lower_mod = @import("lower.zig");
const lower = lower_mod.lower;
const mem = @import("../util/mem.zig");

/// How the member node `node` is lowered. The only member of a ZON file is its root expression
fn ownerOf(ctx: anytype, key: OwnerKey, mode: Parse.Mode, node: ast.SyntaxNode) engine.Error!lower_mod.Owner {
    if (mode == .zon) return .zon;
    return if (try fieldIsName(ctx, key, node)) .bare_field else .member;
}

/// Enum members and union fields written as just a name (no `:`): the type expression position
/// holds the name. Fields of tuple-like structs have no `:` either, but there it is a type, so
/// the kind of the enclosing container must come from the ItemTree
fn fieldIsName(ctx: anytype, key: OwnerKey, node: ast.SyntaxNode) engine.Error!bool {
    if (node.kind() != .container_field or (ast.ContainerField{ .syntax = node }).name() != null) return false;
    const tree = try ctx.get(syntax.FileItemTree, key.file);
    for (tree.items) |it| if (it.ast_id == key.item) {
        const kind = tree.containers[it.container].kind;
        return kind == .@"enum" or kind == .@"union";
    };
    return false;
}

/// BodyOwner: a container member in a file (identified by its stable AstId)
pub const OwnerKey = struct {
    file: Vfs.FileId,
    item: ItemTree.AstId,
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

    /// A Body together with the source of the member it was lowered from: when the text is
    /// unchanged, the next computation reuses it directly (reference counted, the same way
    /// `ParseFile` reuses an old result)
    const Owned = struct {
        body: Body,
        refs: std.atomic.Value(u32) = .init(1),
        source_hash: u64,
        owner: lower_mod.Owner,

        fn of(v: Value) *Owned {
            return @alignCast(@fieldParentPtr("body", @constCast(v)));
        }
    };

    /// Any edit in a file changes `FileAstIdMap` (compared by pointer), so the Body of every
    /// member is recomputed: when the source text of the member and the lowering parameters are
    /// unchanged, the previous Body is reused (lowering reads only the member's own syntax tree,
    /// and positions are relative to the start of the member) instead of lowering again.
    /// Features that need every member of the file, such as inactive code, would otherwise
    /// re-lower thousands of members on every edit in a large file
    pub fn computeIncremental(ctx: anytype, key: Key, prev: ?Value) engine.Error!Value {
        const map = try ctx.get(syntax.FileAstIdMap, key.file);
        const parse = try ctx.get(syntax.ParseFile, key.file);
        // When it is not found (the member was deleted), lower the root node as a member: it is
        // not a member, so the Body is empty
        const found = map.get(key.item);
        const node = found orelse parse.rootNode();
        const owner: lower_mod.Owner = if (found != null) try ownerOf(ctx, key, parse.mode, node) else .member;
        const source_hash = std.hash.Wyhash.hash(0, node.text(parse.source));
        if (prev) |p| {
            const o = Owned.of(p);
            if (o.source_hash == source_hash and o.owner == owner) {
                _ = o.refs.fetchAdd(1, .monotonic);
                return p;
            }
        }
        const gpa = ctx.db.gpa;
        const result = try gpa.create(Owned);
        errdefer gpa.destroy(result);
        result.* = .{ .body = try lower(gpa, node, owner), .source_hash = source_hash, .owner = owner };
        return &result.body;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b or a.eql(b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const o = Owned.of(v.*);
        if (o.refs.fetchSub(1, .acq_rel) != 1) return;
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
