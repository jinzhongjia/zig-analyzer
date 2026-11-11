//! Syntax-layer queries.
//!
//! The ctx parameter of `compute` is `anytype` so that these queries can be registered in
//! different Db types (e.g. a test-only Db).

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const inputs = @import("../base/inputs.zig");
const Parse = @import("Parse.zig");
const ItemTree = @import("ItemTree.zig");
const ast = @import("ast.zig");
const mem = @import("../util/mem.zig");
const offsets = @import("../util/offsets.zig");

/// File contents: uses `FileText` when present (open documents, files loaded by the project),
/// otherwise reads from disk.
///
/// Lets name resolution and type inference access any file (standard library, dependency
/// packages) from inside queries. Contents read from disk are not invalidated when the disk
/// changes (there is no corresponding input); it is recomputed only when `FileText` is set.
pub const SourceText = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    /// If `owned`, this query owns the contents; otherwise they borrow the value of `FileText`
    pub const Value = struct { text: []const u8, owned: bool };

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        if (try ctx.get(inputs.FileText, file)) |text| return .{ .text = text, .owned = false };
        // Test Db without a Vfs
        if (comptime @TypeOf(ctx.db.env) == void) return .{ .text = "", .owned = false };
        const vfs: *Vfs = ctx.db.env.vfs;
        const text = vfs.readFromDisk(file, ctx.db.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.FileTooBig => null,
        };
        return .{ .text = text orelse "", .owned = text != null };
    }

    /// A borrowed old value may already have been freed along with `FileText` and must not be
    /// read: always treat it as changed
    pub fn eql(_: Value, _: Value) bool {
        return false;
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        if (v.owned) gpa.free(v.text);
    }
};

/// Line start offsets of `SourceText` (the table of `offsets.LineIndex`): built once per revision
/// of the text, so that the requests and the diagnostics on one text share it
pub const LineStarts = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = []const u32;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        return offsets.lineStarts(ctx.db.gpa, (try ctx.get(SourceText, file)).text);
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u32, a, b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }

    pub fn bytes(v: Value) usize {
        return v.len * @sizeOf(u32);
    }
};

/// Syntax tree of a file. Always treated as changed after the text changes (no cutoff); ItemTree
/// stops the change from propagating.
/// Parse results use the most memory (about a dozen times the size of the source): only the few
/// most recently used are kept; the others are evicted and reparsed on demand
pub const parse_lru = 64;
/// Byte limit on parse results: a single large file can by itself exceed the memory implied by
/// the count limit
pub const parse_lru_bytes = 128 * 1024 * 1024;

/// The syntax rules files are parsed by; set when the zig version is confirmed after startup, and
/// all files are parsed again when it changes
pub const SyntaxDialect = struct {
    pub const kind: engine.Kind = .input;
    pub const Key = void;
    pub const Value = Parse.Dialect;
    pub const default: Value = .latest;
};

pub const ParseFile = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *Parse;
    pub const lru = parse_lru;
    pub const lru_bytes = parse_lru_bytes;

    /// An incremental parse result reuses the previous tree's nodes and holds a reference to it:
    /// count the arenas of the whole chain
    pub fn bytes(v: Value) usize {
        return @sizeOf(Parse) + v.chain_bytes;
    }

    /// Picks the parse mode by path (`.zon` is ZON). When there is a previous result of the same
    /// dialect, attempts a local reparse (the mode is kept and the result is the same as a full
    /// parse; see `Parse.reparse`)
    pub fn computeIncremental(ctx: anytype, file: Key, prev: ?Value) engine.Error!Value {
        const text = (try ctx.get(SourceText, file)).text;
        const dialect = try ctx.get(SyntaxDialect, {});
        if (prev) |old| if (old.dialect == dialect) return Parse.reparse(ctx.db.gpa, old, text);
        // The test Db without a Vfs only has Zig files
        const mode: Parse.Mode = if (comptime @TypeOf(ctx.db.env) == void) .zig else Parse.modeOf(ctx.db.env.vfs.path(file));
        return Parse.createIn(ctx.db.gpa, text, mode, dialect);
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b;
    }

    pub fn deinit(v: *Value, _: Allocator) void {
        v.*.destroy();
    }
};

/// Declaration skeleton of a file; the most important early cutoff point.
pub const FileItemTree = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const ItemTree;
    /// Bounds memory in long sessions: every visited file has one, which can reach 50 MB in a
    /// large project (the Zig compiler sources and standard library).
    /// Evicted ones are rebuilt on demand; when the dependencies are unchanged, the original
    /// changed_at is kept and downstream is not recomputed. When the file changed while its tree
    /// was evicted, the rebuilt tree is compared by `fingerprint`: an edit in a function body or a
    /// comment then does not recompute everything that depends on the tree
    pub const lru = 16 * 1024;
    pub const lru_bytes = 32 * 1024 * 1024;

    pub fn bytes(v: Value) usize {
        return @sizeOf(ItemTree) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(ParseFile, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(ItemTree);
        errdefer gpa.destroy(result);
        result.* = try ItemTree.build(gpa, parse.rootNode(), parse.mode);
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.eql(b);
    }

    pub fn fingerprint(v: Value) u128 {
        return v.fingerprint();
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const t: *ItemTree = @constCast(v.*);
        t.deinit(gpa);
        gpa.destroy(t);
    }
};

/// AstId → node in the current syntax tree. Rebuilt with every parse and used only for reading;
/// must not become part of other cached results.
/// Summary of a member: its position and the names it may mention
pub const ItemSummary = struct {
    /// Start offset of the member node in the file; null when the node is not found
    offset: ?u32,
    /// Start offset and length of the name token in the file; the length is 0 when there is no
    /// name (or the node is not found)
    name_offset: u32 = 0,
    name_len: u32 = 0,
    /// Bloom filter of the identifiers appearing in the member node (including nested members):
    /// tells whether it "may mention a name", with false positives but no false negatives
    names: [4]u64 = @splat(0),

    pub fn mayMention(s: ItemSummary, name: []const u8) bool {
        const bits = bloomBits(name);
        return s.names[bits[0] / 64] & bitMask(bits[0]) != 0 and s.names[bits[1] / 64] & bitMask(bits[1]) != 0;
    }

    fn add(s: *ItemSummary, name: []const u8) void {
        for (bloomBits(name)) |b| s.names[b / 64] |= bitMask(b);
    }

    fn bloomBits(name: []const u8) [2]u8 {
        const h = std.hash.Wyhash.hash(0, name);
        return .{ @truncate(h), @truncate(h >> 8) };
    }

    fn bitMask(b: u8) u64 {
        return @as(u64, 1) << @intCast(b % 64);
    }
};

/// Summaries of the members and containers in a file (one-to-one with `ItemTree.items` /
/// `containers`). The value is small and never evicted: uses that only need positions or only
/// need to know whether a member mentions a name (find references, call-site seeding, locating
/// containers inside bodies, workspace symbol) need not reparse evicted parse results, nor
/// generate Body for unrelated members.
/// A separate query rather than part of ItemTree: edits inside function bodies change it, while
/// ItemTree must stay unchanged
pub const ItemSummaries = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const Summaries;

    pub fn bytes(v: Value) usize {
        return @sizeOf(Summaries) + v.items.len * @sizeOf(ItemSummary) + v.container_offsets.len * @sizeOf(?u32);
    }

    pub const Summaries = struct {
        items: []ItemSummary,
        /// Start offset of the container node in the file; null when the node is not found
        container_offsets: []?u32,
    };

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const items = try ctx.get(FileItemTree, file);
        const map = try ctx.get(FileAstIdMap, file);
        const gpa = ctx.db.gpa;
        const out = try gpa.create(Summaries);
        errdefer gpa.destroy(out);
        out.items = try gpa.alloc(ItemSummary, items.items.len);
        errdefer gpa.free(out.items);
        out.container_offsets = try gpa.alloc(?u32, items.containers.len);
        // Decoded names are only hashed; temporary allocations are freed after this computation
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        for (items.items, out.items) |it, *o| {
            const node = map.get(it.ast_id) orelse {
                o.* = .{ .offset = null };
                continue;
            };
            o.* = .{ .offset = node.offset };
            if (ast.memberName(node, ItemTree.bareFieldNames(items.containers[it.container].kind))) |t| {
                o.name_offset = t.offset;
                o.name_len = @intCast(t.text.len);
            }
            try collectNames(scratch.allocator(), node, o);
        }
        for (items.containers, out.container_offsets) |c, *o| o.* = if (map.get(c.ast_id)) |n| n.offset else null;
        return out;
    }

    fn collectNames(a: Allocator, node: ast.SyntaxNode, s: *ItemSummary) Allocator.Error!void {
        var it = node.children();
        while (it.next()) |e| switch (e) {
            .token => |t| if (t.kind == .identifier) s.add(try ast.identNameAlloc(a, t.text)),
            .node => |c| try collectNames(a, c, s),
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, std.mem.sliceAsBytes(a.items), std.mem.sliceAsBytes(b.items)) and
            std.mem.eql(?u32, a.container_offsets, b.container_offsets);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const s: *Summaries = @constCast(v.*);
        gpa.free(s.items);
        gpa.free(s.container_offsets);
        gpa.destroy(s);
    }
};

/// Keeps only the name Bloom bits: position changes (from a changed file prefix and the like) do
/// not invalidate semantic candidate filtering.
pub const ItemNames = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = []const [4]u64;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const summaries = try ctx.get(ItemSummaries, file);
        const names = try ctx.db.gpa.alloc([4]u64, summaries.items.len);
        for (summaries.items, names) |item, *out| out.* = item.names;
        return names;
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

/// Positions of containers relative to their owning members: keeps what lexical scopes and
/// container layout depend on, without depending on absolute positions in the file.
pub const ContainerRels = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = []const ?u32;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const tree = try ctx.get(FileItemTree, file);
        const summaries = try ctx.get(ItemSummaries, file);
        const rels = try ctx.db.gpa.alloc(?u32, tree.containers.len);
        for (tree.containers, summaries.container_offsets, rels) |container, offset, *out| {
            const parent = container.parent_item orelse {
                out.* = null;
                continue;
            };
            out.* = if (offset != null and summaries.items[parent].offset != null)
                offset.? - summaries.items[parent].offset.?
            else
                null;
        }
        return rels;
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(?u32, a, b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

/// The nodes in the value point into the parse result: holds a reference to it, so the value
/// stays valid after the `ParseFile` value is evicted
pub const FileAstIdMap = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const ItemTree.AstIdMap;
    pub const lru = parse_lru;
    pub const lru_bytes = parse_lru_bytes;

    const Owned = struct {
        map: ItemTree.AstIdMap,
        parse: *Parse,
    };

    /// The hash table and the parse result it retains (which may still be held here after
    /// `ParseFile` is evicted)
    pub fn bytes(v: Value) usize {
        const owned: *const Owned = @fieldParentPtr("map", v);
        return owned.map.bytes() + owned.parse.chain_bytes;
    }

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(ParseFile, file);
        const items = try ctx.get(FileItemTree, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(Owned);
        errdefer gpa.destroy(result);
        result.* = .{ .map = try ItemTree.AstIdMap.build(gpa, items, parse.rootNode()), .parse = parse.retain() };
        return &result.map;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b;
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const owned: *Owned = @alignCast(@fieldParentPtr("map", @constCast(v.*)));
        owned.map.deinit(gpa);
        owned.parse.destroy();
        gpa.destroy(owned);
    }
};

test {
    _ = @import("queries_test.zig");
}
