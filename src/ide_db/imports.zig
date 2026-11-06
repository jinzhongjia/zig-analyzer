//! Auto-import: its own declaration index, the public export closure, and safe source edits.
//!
//! `FileDecls` derives from the ItemTree the declarations accessible from the file root,
//! `FileLinks` records the namespace each declaration refers to and the canonical target of
//! aliases, and `Exports` expands the closure along public members. Namespaces and aliases are
//! both evaluated by `Resolver.namespaceOf` / `aliasTarget`, the same implementation as goto,
//! hover and other features; namespaces in conditional form (`if` / `switch`) are computed by
//! inference.

const std = @import("std");
const database = @import("../database.zig");
const engine = @import("../db/engine.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const FileId = @import("../base/Vfs.zig").FileId;
const ItemTree = @import("../syntax/ItemTree.zig");
const ast = @import("../syntax/ast.zig");
const Body = @import("../hir/Body.zig");
const sema_queries = @import("../sema/queries.zig");
const hir = @import("../hir/queries.zig");
const Allocator = std.mem.Allocator;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const mem = @import("../util/mem.zig");
const organize_imports = @import("organize_imports.zig");
const fuzzy = @import("fuzzy.zig");
const symbol_kind = @import("symbol_kind.zig");

pub const Edit = struct { start: u32, end: u32, text: []const u8 };
pub const Candidate = struct {
    label: []const u8,
    /// Declaration kinds as in `symbol_kind`; `module` and `file` are a newly imported module or
    /// file itself
    kind: enum { function, constant, variable, namespace, @"struct", @"enum", type, module, file },
    filter: []const u8,
    qualifier: []const u8,
    /// Match score (see `fuzzy`) multiplied by the weight of the source and the depth factor of
    /// the path; higher scores come first
    score: f32,
    doc: ?[]const u8 = null,
    import_edit: ?Edit = null,
    target: Target,
};
pub const Result = struct { items: []const Candidate, is_incomplete: bool = false };
pub const Declaration = struct { file: FileId, item: u32 };
/// The definition a candidate refers to: provides the signature, documentation and location when
/// the completion item is selected
pub const Target = union(enum) {
    decl: Declaration,
    /// The module or file itself
    file: FileId,
};

/// Maximum evaluation depth of alias chains and member accesses, the same as the alias chain limit
/// of `Resolver`
const max_depth = 100;

/// Completion fuzzy-matches the paths of at most this many segments below a namespace
/// (`std.mem.eql` is 2 segments below `std`); deeper ones are matched only by name prefix
pub const shallow_depth = 2;

/// Only Zig source files are indexed: a module root can be `.zon` or any data file (such as JSON
/// added by `addAnonymousImport`); parsing those as Zig is meaningless, and slow for large files
pub fn isZigSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig");
}

// ── File declarations ──────────────────────────────────────────────

pub const Decl = struct {
    name: []const u8,
    item: u32,
    kind: ItemTree.Item.Kind,
    is_pub: bool,
    is_extern: bool,
    container: u32,
    /// Name of the top-level ancestor (through which it is accessed); null for top-level decls
    root: ?[]const u8,
    /// Path to access it from the file root (each segment escaped)
    path: []const u8,
    /// The container when it refers to a container in this file (a container literal,
    /// `@This()`, an alias to a container in the same file); references to other files are
    /// evaluated by `Eval`
    local: ?u32,
    doc: ?[]const u8,
    /// The kind as far as the syntax determines it (const and var); completion candidates show
    /// their kind from it without inferring the declaration's type
    form: symbol_kind.Form = .unknown,
};

/// A declaration reachable from the file root through public members (including public aliases to
/// private containers in the same file): `decl` is an index into `DeclIndex.decls`
pub const Public = struct { decl: u32, path: []const u8 };

/// Containers that cannot be accessed from the file root, and the outer container of the file root
const no_container = std.math.maxInt(u32);

pub const DeclIndex = struct {
    arena: std.heap.ArenaAllocator.State,
    /// Sorted by name (`orderName`)
    decls: []const Decl = &.{},
    /// Sorted by name (`orderName`)
    public_decls: []const Public = &.{},
    /// Indices into `decls`, sorted by item
    by_item: []const u32 = &.{},
    /// Indices into `decls` grouped by container, sorted by name within each group: the members
    /// of container c are `members[member_start[c]..member_start[c + 1]]`
    members: []const u32 = &.{},
    member_start: []const u32 = &.{},
    /// Outer container of each container (the container of the member that defines it), indexed
    /// by container
    outer: []const u32 = &.{},
    /// Lexical path of each container from the file root (escaped); "" for the root container and
    /// null for unreachable containers
    container_paths: []const ?[]const u8 = &.{},

    /// Index range in `decls` of the declarations whose names start with `prefix`
    /// (case-insensitive)
    pub fn matching(index: *const DeclIndex, prefix: []const u8) struct { start: usize, end: usize } {
        const start = prefixStart(Decl, index.decls, prefix);
        var end = start;
        while (end < index.decls.len and std.ascii.startsWithIgnoreCase(index.decls[end].name, prefix)) : (end += 1) {}
        return .{ .start = start, .end = end };
    }

    pub fn matchingPublic(index: *const DeclIndex, prefix: []const u8) []const Public {
        var low: usize = 0;
        var high = index.public_decls.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (std.ascii.lessThanIgnoreCase(index.decls[index.public_decls[mid].decl].name, prefix)) low = mid + 1 else high = mid;
        }
        var end = low;
        while (end < index.public_decls.len and std.ascii.startsWithIgnoreCase(index.decls[index.public_decls[end].decl].name, prefix)) : (end += 1) {}
        return index.public_decls[low..end];
    }

    pub fn byItem(index: *const DeclIndex, item: u32) ?*const Decl {
        var low: usize = 0;
        var high = index.by_item.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const decl = &index.decls[index.by_item[mid]];
            if (decl.item == item) return decl;
            if (decl.item < item) low = mid + 1 else high = mid;
        }
        return null;
    }

    pub fn containerMembers(index: *const DeclIndex, container: u32) []const u32 {
        if (container + 1 >= index.member_start.len) return &.{};
        return index.members[index.member_start[container]..index.member_start[container + 1]];
    }

    /// The declaration named `name` in the container
    pub fn member(index: *const DeclIndex, container: u32, name: []const u8) ?*const Decl {
        const members = index.containerMembers(container);
        var low: usize = 0;
        var high = members.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const decl = &index.decls[members[mid]];
            switch (orderName(decl.name, name)) {
                .eq => return decl,
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        return null;
    }

    /// Scope over the container hierarchy: looks up the name from `container` outward
    pub fn lookup(index: *const DeclIndex, container: u32, name: []const u8) ?*const Decl {
        var c = container;
        while (c != no_container and c < index.outer.len) : (c = index.outer[c]) {
            if (index.member(c, name)) |decl| return decl;
        }
        return null;
    }
};

/// A new file-level binding only needs to avoid real declarations: container members (ItemTree),
/// parameters of other functions, and local variables and captures (function bodies).
/// Member accesses, initializer field names, labels, type references and plain name references
/// are not declarations and cause no conflicts, so keystrokes need not scan and hash every
/// identifier in the whole syntax tree.
pub const BindingNames = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct { arena: std.heap.ArenaAllocator.State, names: []const []const u8 };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var list: std.ArrayList([]const u8) = .empty;
        const parse = try ctx.get(database.syntax.ParseFile, file);
        try collect(&list, temp, parse.rootNode());
        const tree = try ctx.get(database.syntax.FileItemTree, file);
        for (tree.items) |item| if (item.kind != .@"test") if (item.name) |name| try list.append(temp, name);
        std.mem.sort([]const u8, list.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.less);
        var unique: usize = 0;
        for (list.items) |name| {
            if (unique != 0 and std.mem.eql(u8, list.items[unique - 1], name)) continue;
            list.items[unique] = name;
            unique += 1;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const sorted = try a.alloc([]const u8, unique);
        for (list.items[0..unique], sorted) |name, *out| out.* = try a.dupe(u8, name);
        return .{ .arena = arena.state, .names = sorted };
    }

    fn collect(names: *std.ArrayList([]const u8), scratch: Allocator, node: ast.SyntaxNode) Allocator.Error!void {
        switch (node.kind()) {
            .param => if ((ast.Param{ .syntax = node }).name()) |token| try names.append(scratch, try ast.identNameAlloc(scratch, token.text)),
            .var_decl => if ((ast.VarDecl{ .syntax = node }).name()) |token| try names.append(scratch, try ast.identNameAlloc(scratch, token.text)),
            .payload => {
                var bindings = (ast.Payload{ .syntax = node }).bindings();
                while (bindings.next()) |binding| try names.append(scratch, try ast.identNameAlloc(scratch, binding.name.text));
                return;
            },
            else => {},
        }
        var children = node.children();
        while (children.nextNode()) |child| try collect(names, scratch, child);
    }

    pub fn contains(value: Value, name: []const u8) bool {
        return std.sort.binarySearch([]const u8, value.names, name, struct {
            fn order(needle: []const u8, item: []const u8) std.math.Order {
                return std.mem.order(u8, needle, item);
            }
        }.order) != null;
    }

    pub fn eql(left: Value, right: Value) bool {
        return deepEql(left.names, right.names);
    }

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

/// Small index that is never evicted: this file's ItemTree, and whether each container is
/// reachable from the file root (evaluated by `Resolver`)
pub const FileDecls = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = *const DeclIndex;

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        var index: DeclIndex = .{ .arena = undefined };
        if (isZigSource(ctx.db.env.vfs.path(file))) {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
            var b: DeclBuilder = .{
                .r = &r,
                .file = file,
                .tree = try ctx.get(database.syntax.FileItemTree, file),
                .a = arena.allocator(),
                .temp = scratch.allocator(),
            };
            index = try b.build();
        }
        index.arena = arena.state;
        const out = try gpa.create(DeclIndex);
        out.* = index;
        return out;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.decls, b.decls) and deepEql(a.public_decls, b.public_decls) and deepEql(a.by_item, b.by_item) and
            deepEql(a.members, b.members) and deepEql(a.member_start, b.member_start) and deepEql(a.outer, b.outer) and
            deepEql(a.container_paths, b.container_paths);
    }
    pub fn bytes(v: Value) usize {
        return @sizeOf(DeclIndex) + mem.arenaBytes(v.arena);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        var arena = v.*.arena.promote(gpa);
        arena.deinit();
        gpa.destroy(@constCast(v.*));
    }
};

const DeclBuilder = struct {
    r: *Resolver,
    file: FileId,
    tree: *const ItemTree,
    /// Arena for the result
    a: Allocator,
    temp: Allocator,
    /// Whether a container is accessible from the file root: only when the value of a named const /
    /// var is that container (initialized directly with the container literal)
    reachable: []?bool = undefined,
    names: []?[]const u8 = undefined,
    paths: []?[]const u8 = undefined,

    fn build(b: *DeclBuilder) resolve.Error!DeclIndex {
        const items = b.tree.items;
        const containers = b.tree.containers;
        b.reachable = try b.temp.alloc(?bool, containers.len);
        @memset(b.reachable, null);
        b.names = try b.temp.alloc(?[]const u8, items.len);
        @memset(b.names, null);
        b.paths = try b.temp.alloc(?[]const u8, items.len);
        @memset(b.paths, null);

        var list: std.ArrayList(Decl) = .empty;
        for (items, 0..) |it, i| {
            switch (it.kind) {
                .@"fn", .@"const", .@"var" => {},
                else => continue,
            }
            if (it.name == null or !try b.isReachable(it.container)) continue;
            const item: u32 = @intCast(i);
            // Methods (whose first parameter is a value of or pointer to the enclosing container)
            // are called through instances and are not importable functions
            if (it.kind == .@"fn" and it.container != 0 and try b.isMethod(item)) continue;
            try list.append(b.temp, .{
                .name = try b.ownName(item),
                .item = item,
                .kind = it.kind,
                .is_pub = it.flags.is_pub,
                .is_extern = it.flags.is_extern,
                .container = it.container,
                .root = try b.rootName(it.container),
                .path = try b.pathOf(item),
                .local = try b.localNamespace(item),
                .doc = if (it.doc) |d| try b.a.dupe(u8, d) else null,
                .form = if (it.kind == .@"fn") .unknown else if (try b.r.itemNode(b.file, item)) |node| symbol_kind.declForm(node) else .unknown,
            });
        }
        std.mem.sort(Decl, list.items, {}, nameLess(Decl));
        const decls = try b.a.dupe(Decl, list.items);

        const by_item = try b.a.alloc(u32, decls.len);
        for (by_item, 0..) |*d, i| d.* = @intCast(i);
        std.mem.sort(u32, by_item, decls, struct {
            fn less(all: []const Decl, x: u32, y: u32) bool {
                return all[x].item < all[y].item;
            }
        }.less);

        // decls is already sorted by name; placed in order into each container's group, every
        // group stays sorted by name
        const member_start = try b.a.alloc(u32, containers.len + 1);
        @memset(member_start, 0);
        for (decls) |d| member_start[d.container + 1] += 1;
        for (1..member_start.len) |i| member_start[i] += member_start[i - 1];
        const members = try b.a.alloc(u32, decls.len);
        const fill = try b.temp.dupe(u32, member_start[0..containers.len]);
        for (decls, 0..) |d, i| {
            members[fill[d.container]] = @intCast(i);
            fill[d.container] += 1;
        }

        const outer = try b.a.alloc(u32, containers.len);
        for (containers, outer, 0..) |c, *o, i| {
            const parent = c.parent_item orelse {
                o.* = no_container;
                continue;
            };
            o.* = if (try b.isReachable(@intCast(i))) items[parent].container else no_container;
        }

        const container_paths = try b.a.alloc(?[]const u8, containers.len);
        @memset(container_paths, null);
        if (containers.len != 0) container_paths[0] = "";
        for (containers, 0..) |c, i| {
            if (i == 0 or !try b.isReachable(@intCast(i))) continue;
            const parent = c.parent_item orelse continue;
            container_paths[i] = try b.pathOf(parent);
        }

        var index: DeclIndex = .{
            .arena = undefined,
            .decls = decls,
            .by_item = by_item,
            .members = members,
            .member_start = member_start,
            .outer = outer,
            .container_paths = container_paths,
        };
        index.public_decls = try b.publicPaths(&index);
        return index;
    }

    /// Paths reachable from the file root through public members: a public alias may refer to a
    /// private container of this file; other files are not expanded
    fn publicPaths(b: *DeclBuilder, index: *const DeclIndex) Allocator.Error![]const Public {
        const Pending = struct { container: u32, path: []const u8, lexical: bool };
        var queue: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        try queue.append(b.temp, .{ .container = 0, .path = "", .lexical = true });
        try seen.put(b.temp, 0, {});
        var list: std.ArrayList(Public) = .empty;
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const pending = queue.items[cursor];
            for (index.containerMembers(pending.container)) |d| {
                const decl = index.decls[d];
                if (!decl.is_pub) continue;
                const path = if (pending.lexical) decl.path else try appendName(b.a, pending.path, decl.name);
                try list.append(b.temp, .{ .decl = d, .path = path });
                const ns = decl.local orelse continue;
                const visited = try seen.getOrPut(b.temp, ns);
                if (!visited.found_existing) try queue.append(b.temp, .{
                    .container = ns,
                    .path = path,
                    .lexical = pending.lexical and b.tree.containers[ns].parent_item == decl.item,
                });
            }
        }
        std.mem.sort(Public, list.items, index.decls, struct {
            fn less(decls: []const Decl, x: Public, y: Public) bool {
                const order = orderName(decls[x.decl].name, decls[y.decl].name);
                if (order != .eq) return order == .lt;
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.less);
        return b.a.dupe(Public, list.items);
    }

    fn isReachable(b: *DeclBuilder, container: u32) resolve.Error!bool {
        if (container == 0) return true;
        if (b.reachable[container]) |known| return known;
        // Mark as unreachable first, so self-referential structures do not recurse infinitely
        b.reachable[container] = false;
        const result = blk: {
            const parent = b.tree.containers[container].parent_item orelse break :blk false;
            const it = b.tree.items[parent];
            if (it.kind != .@"const" and it.kind != .@"var" or it.name == null) break :blk false;
            const ns = try namespaceOfDecl(b.r, b.file, parent) orelse break :blk false;
            if (ns.file != b.file or ns.container != container) break :blk false;
            break :blk try b.isReachable(it.container);
        };
        b.reachable[container] = result;
        return result;
    }

    /// The type of the first parameter of function `item` is its enclosing container
    /// (`self: Self`, `self: *const @This()`, `s: *S`)
    fn isMethod(b: *DeclBuilder, item: u32) resolve.Error!bool {
        const node = try b.r.itemNode(b.file, item) orelse return false;
        const proto = (ast.FnDecl{ .syntax = node }).proto() orelse (if (node.kind() == .fn_proto) ast.FnProto{ .syntax = node } else return false);
        var params = proto.params();
        const first = params.next() orelse return false;
        var ty = (ast.Param{ .syntax = first }).typeExpr() orelse return false;
        // `*T`, `*const T`: take the pointee type
        while (ty.kind() == .ptr_type) {
            var last: ?ast.SyntaxNode = null;
            var children = ty.children();
            while (children.nextNode()) |c| switch (c.kind()) {
                .sentinel, .align_clause, .addrspace_clause => {},
                else => last = c,
            };
            ty = last orelse return false;
        }
        const container = b.tree.items[item].container;
        switch (ty.kind()) {
            .builtin_call => {
                const name = (ast.BuiltinCall{ .syntax = ty }).name() orelse return false;
                return std.mem.eql(u8, name.text, "@This");
            },
            .name_ref => {
                const token = (ast.NameRef{ .syntax = ty }).name() orelse return false;
                const name = try ast.identNameAlloc(b.temp, token.text);
                const found = b.lookup(container, name) orelse return false;
                const ns = try namespaceOfDecl(b.r, b.file, found) orelse return false;
                return ns.file == b.file and ns.container == container;
            },
            else => return false,
        }
    }

    fn ownName(b: *DeclBuilder, item: u32) Allocator.Error![]const u8 {
        if (b.names[item]) |name| return name;
        const name = try b.a.dupe(u8, b.tree.items[item].name.?);
        b.names[item] = name;
        return name;
    }

    fn rootName(b: *DeclBuilder, container: u32) Allocator.Error!?[]const u8 {
        if (container == 0) return null;
        var c = container;
        while (true) {
            const parent = b.tree.containers[c].parent_item.?;
            const outer = b.tree.items[parent].container;
            if (outer == 0) return try b.ownName(parent);
            c = outer;
        }
    }

    fn pathOf(b: *DeclBuilder, item: u32) Allocator.Error![]const u8 {
        if (b.paths[item]) |path| return path;
        const it = b.tree.items[item];
        const name = try b.ownName(item);
        const segment = try renderName(b.temp, name);
        const path = if (it.container == 0)
            (if (std.mem.eql(u8, segment, name)) name else try b.a.dupe(u8, segment))
        else
            try joinPath(b.a, try b.pathOf(b.tree.containers[it.container].parent_item.?), segment);
        b.paths[item] = path;
        return path;
    }

    /// The container, when it refers to a container in this file accessible from the file root
    fn localNamespace(b: *DeclBuilder, item: u32) resolve.Error!?u32 {
        const kind = b.tree.items[item].kind;
        if (kind != .@"const" and kind != .@"var") return null;
        const ns = try namespaceOfDecl(b.r, b.file, item) orelse return null;
        if (ns.file != b.file or !try b.isReachable(ns.container)) return null;
        return ns.container;
    }

    fn lookup(b: *DeclBuilder, container: u32, name: []const u8) ?u32 {
        var c = container;
        while (true) {
            if (Resolver.lookupDecl(b.tree, c, name)) |found| return found;
            const parent = b.tree.containers[c].parent_item orelse return null;
            c = b.tree.items[parent].container;
        }
    }
};

// ── Cross-file evaluation ──────────────────────────────────────────

/// The namespace a declaration refers to (see `DeclNamespace`)
fn namespaceOfDecl(r: *Resolver, file: FileId, item: u32) resolve.Error!?Namespace {
    return r.ctx.get(DeclNamespace, try r.ownerKey(file, item));
}

/// The namespace a declaration refers to: `Resolver.namespaceOf`; when the initializer is in
/// conditional form (`if` / `switch`), its value is computed by inference
/// (`pub const X = if (cond) A else B;` takes the branch selected at comptime). Cached per
/// declaration: a file can have thousands of declarations, and when the read transaction that
/// indexes it is interrupted by an edit, declarations already computed need not be recomputed;
/// declarations unchanged by an edit also hit the cache directly.
pub const DeclNamespace = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = ?Namespace;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const item = try itemOf(&r, key) orelse return null;
        return computeNamespace(&r, key.file, item);
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a, b);
    }
};

/// The canonical target of a declaration as an alias (`Resolver.aliasTarget`; the declaration
/// itself when it is not an alias), cached per declaration (like `DeclNamespace`)
pub const DeclTarget = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = Declaration;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const item = try itemOf(&r, key) orelse return .{ .file = key.file, .item = 0 };
        return switch (try r.aliasTarget(.{ .item = .{ .file = key.file, .item = item } })) {
            .item => |it| .{ .file = it.file, .item = it.item },
            else => .{ .file = key.file, .item = item },
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a, b);
    }
};

fn itemOf(r: *Resolver, key: hir.OwnerKey) resolve.Error!?u32 {
    for ((try r.itemTree(key.file)).items, 0..) |it, i| if (it.ast_id == key.item) return @intCast(i);
    return null;
}

fn computeNamespace(r: *Resolver, file: FileId, item: u32) resolve.Error!?Namespace {
    if (try r.namespaceOf(.{ .item = .{ .file = file, .item = item } })) |ns| return ns;
    const tree = try r.itemTree(file);
    if (tree.items[item].kind != .@"const") return null;
    const body = try r.body(file, item);
    const value = body.value orelse return null;
    switch (body.expr(value)) {
        .@"if", .@"switch" => {},
        else => return null,
    }
    const tv = try r.ctx.get(sema_queries.DeclType, .{ .owner = try r.ownerKey(file, item) });
    const t = tv.asType() orelse return null;
    return sema_queries.namespaceOfType(r, t);
}

/// The namespaces the declarations of a file refer to and the canonical targets of aliases (by
/// index into `DeclIndex.decls`). Used by both completion and the expansion of export closures.
pub const FileLinks = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct {
        arena: std.heap.ArenaAllocator.State,
        namespaces: []const ?Namespace = &.{},
        targets: []const Declaration = &.{},
    };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const index = try ctx.get(FileDecls, file);
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const namespaces = try a.alloc(?Namespace, index.decls.len);
        const targets = try a.alloc(Declaration, index.decls.len);
        for (index.decls, namespaces, targets) |decl, *ns, *target| {
            ns.* = try namespaceOfDecl(&r, file, decl.item);
            target.* = try ctx.get(DeclTarget, try r.ownerKey(file, decl.item));
        }
        return .{ .arena = arena.state, .namespaces = namespaces, .targets = targets };
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.namespaces, b.namespaces) and deepEql(a.targets, b.targets);
    }

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

// ── Files used only by tests ───────────────────────────────────────

/// The by-path `@import("x.zig")` calls of a file and whether each is used only for tests: inside
/// a test declaration, or inside a non-pub top-level declaration used only by tests. A non-pub
/// top-level declaration is used only by tests when production code does not reference it but
/// test declarations do (directly or via declarations likewise used only by tests), e.g.
/// `const World = @import("x_test.zig").World;` used only in tests and in helper functions
/// called by tests: the compiler, which analyzes lazily, compiles it only in tests. Depends only
/// on this file's syntax tree.
pub const ImportSites = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct {
        arena: std.heap.ArenaAllocator.State,
        specs: []const []const u8 = &.{},
        in_test: []const bool = &.{},
    };

    const Site = struct { spec: []const u8, in_test: bool, decl: ?u32 };
    /// A top-level declaration: its name (null for tests and unnamed ones), whether it is pub, and
    /// the names it references
    const TopDecl = struct { name: ?[]const u8, is_pub: bool, is_test: bool, refs: std.ArrayList([]const u8) = .empty };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        if (!isZigSource(ctx.db.env.vfs.path(file))) return .{ .arena = arena.state };
        const a = arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var sites: std.ArrayList(Site) = .empty;
        var decls: std.ArrayList(TopDecl) = .empty;
        const root = (try ctx.get(database.syntax.ParseFile, file)).rootNode();
        var top = root.children();
        while (top.nextNode()) |node| {
            const index: u32 = @intCast(decls.items.len);
            try decls.append(temp, try topDecl(temp, node));
            try collect(a, temp, node, index, &decls.items[index], &sites);
        }
        // Propagation by name only goes through named non-test declarations
        var by_name: std.StringHashMapUnmanaged(u32) = .empty;
        for (decls.items, 0..) |d, i| if (!d.is_test) if (d.name) |name| try by_name.put(temp, name, @intCast(i));
        // Production code: pub declarations and other non-test top-level content, plus the
        // non-pub declarations they reference
        const live = try temp.alloc(bool, decls.items.len);
        for (decls.items, live) |d, *l| l.* = !d.is_test and (d.is_pub or d.name == null);
        try propagate(temp, decls.items, &by_name, live, null);
        // Test code: test declarations, plus the remaining non-pub declarations they reference.
        // Declarations referenced by neither are dead code and count as production code.
        const tested = try temp.alloc(bool, decls.items.len);
        for (decls.items, tested) |d, *t| t.* = d.is_test;
        try propagate(temp, decls.items, &by_name, tested, live);
        const specs = try a.alloc([]const u8, sites.items.len);
        const in_test = try a.alloc(bool, sites.items.len);
        for (sites.items, specs, in_test) |site, *spec, *flag| {
            spec.* = site.spec;
            flag.* = site.in_test or (if (site.decl) |d| !live[d] and tested[d] else false);
        }
        return .{ .arena = arena.state, .specs = specs, .in_test = in_test };
    }

    /// Also marks the other declarations (by name) referenced by declarations in `marked`, until
    /// nothing changes; declarations already marked in `except` are not marked
    fn propagate(temp: Allocator, decls: []const TopDecl, by_name: *const std.StringHashMapUnmanaged(u32), marked: []bool, except: ?[]const bool) Allocator.Error!void {
        var queue: std.ArrayList(u32) = .empty;
        for (marked, 0..) |m, i| if (m) try queue.append(temp, @intCast(i));
        while (queue.pop()) |i| for (decls[i].refs.items) |ref| {
            const j = by_name.get(ref) orelse continue;
            if (marked[j]) continue;
            if (except) |e| if (e[j]) continue;
            marked[j] = true;
            try queue.append(temp, j);
        };
    }

    fn topDecl(temp: Allocator, node: ast.SyntaxNode) Allocator.Error!TopDecl {
        const is_pub = node.childToken(.keyword_pub) != null;
        switch (node.kind()) {
            .test_decl => return .{ .name = null, .is_pub = false, .is_test = true },
            .var_decl => if ((ast.VarDecl{ .syntax = node }).name()) |t| return .{ .name = try ast.identNameAlloc(temp, t.text), .is_pub = is_pub, .is_test = false },
            .fn_decl => if ((ast.FnDecl{ .syntax = node }).proto()) |proto| if (proto.name()) |t| return .{ .name = try ast.identNameAlloc(temp, t.text), .is_pub = is_pub, .is_test = false },
            else => {},
        }
        return .{ .name = null, .is_pub = is_pub, .is_test = false };
    }

    /// The imports and referenced names in top-level declaration `decl` (index `index`)
    fn collect(a: Allocator, temp: Allocator, node: ast.SyntaxNode, index: u32, decl: *TopDecl, sites: *std.ArrayList(Site)) Allocator.Error!void {
        switch (node.kind()) {
            .name_ref => if ((ast.NameRef{ .syntax = node }).name()) |t| try decl.refs.append(temp, try ast.identNameAlloc(temp, t.text)),
            .builtin_call => if (try pathImport(a, node)) |spec| try sites.append(temp, .{ .spec = spec, .in_test = decl.is_test, .decl = if (decl.is_pub or decl.name == null) null else index }),
            else => {},
        }
        var children = node.children();
        while (children.nextNode()) |child| try collect(a, temp, child, index, decl, sites);
    }

    fn pathImport(a: Allocator, node: ast.SyntaxNode) Allocator.Error!?[]const u8 {
        const call = ast.BuiltinCall{ .syntax = node };
        const name = call.name() orelse return null;
        if (!std.mem.eql(u8, name.text, "@import")) return null;
        var args = call.args();
        const arg = args.next() orelse return null;
        if (arg.kind() != .literal) return null;
        const raw = (arg.firstToken() orelse return null).text;
        const spec = std.zig.string_literal.parseAlloc(a, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return null,
        };
        return if (std.mem.endsWith(u8, spec, ".zig")) spec else null;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.specs, b.specs) and deepEql(a.in_test, b.in_test);
    }

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

/// Files of the project used only by tests (ascending): files reachable via imports from the
/// module roots, but not reachable via non-test imports alone. For example, test files imported
/// only in `test { _ = @import("x_test.zig"); }`, and test helper files imported only by them.
pub const TestOnlyFiles = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = void;
    pub const Value = []const FileId;

    pub fn compute(ctx: *database.Db.Ctx, _: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var r: Resolver = .{ .ctx = ctx, .arena = temp };
        const graph = try ctx.get(database.ModuleGraph.Input, {}) orelse return gpa.dupe(FileId, &.{});
        var roots: std.ArrayList(FileId) = .empty;
        for (graph.modules) |module| if (module.root) |root| try roots.append(temp, root);
        // Files reachable via all imports, and files reachable via non-test imports only: the
        // former minus the latter are used only by tests. Files reachable by neither (such as a
        // new file not imported yet) are not classified as test files.
        const all = try reach(&r, temp, roots.items, true);
        const live = try reach(&r, temp, roots.items, false);
        var out: std.ArrayList(FileId) = .empty;
        for (all.keys()) |file| if (!live.contains(file) and isZigSource(ctx.db.env.vfs.path(file))) try out.append(temp, file);
        std.mem.sort(FileId, out.items, {}, struct {
            fn less(_: void, x: FileId, y: FileId) bool {
                return @backingInt(x) < @backingInt(y);
            }
        }.less);
        return gpa.dupe(FileId, out.items);
    }

    /// Files reachable from `roots` via imports, in breadth-first order starting with the roots;
    /// when `with_tests` is false, imports used only for tests are not followed
    fn reach(r: *Resolver, temp: Allocator, roots: []const FileId, with_tests: bool) resolve.Error!std.AutoArrayHashMapUnmanaged(FileId, void) {
        var reached: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
        for (roots) |root| try reached.put(temp, root, {});
        var i: usize = 0;
        while (i < reached.count()) : (i += 1) {
            const file = reached.keys()[i];
            const sites = try r.ctx.get(ImportSites, file);
            for (sites.specs, sites.in_test) |spec, in_test| {
                if (in_test and !with_tests) continue;
                const target = try r.resolveImport(file, spec) orelse continue;
                try reached.put(temp, target, {});
            }
        }
        return reached;
    }

    pub fn contains(value: Value, file: FileId) bool {
        return std.sort.binarySearch(FileId, value, file, struct {
            fn order(needle: FileId, item: FileId) std.math.Order {
                return std.math.order(@backingInt(needle), @backingInt(item));
            }
        }.order) != null;
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(FileId, a, b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

// ── Public export closure ──────────────────────────────────────────

/// Other Zig source files containing namespaces reachable via public paths in `file` (possibly
/// with duplicates): used for expansion when warming up public export closures in batches
pub fn publicTargets(ctx: *database.Db.Ctx, file: FileId, out: *std.ArrayList(FileId), a: Allocator) engine.Error!void {
    const index = try ctx.get(FileDecls, file);
    const links = try ctx.get(FileLinks, file);
    for (index.public_decls) |p| {
        const ns = links.namespaces[p.decl] orelse continue;
        if (ns.file != file and isZigSource(ctx.db.env.vfs.path(ns.file))) try out.append(a, ns.file);
    }
}

pub const Export = struct {
    /// Points into the value of `FileDecls` (never evicted and never in a cycle, since it reads
    /// only syntax queries; this query depends on it and is recomputed along with it)
    name: []const u8,
    path: []const u8,
    /// Number of segments in the path
    depth: u32,
    kind: ItemTree.Item.Kind,
    is_extern: bool,
    file: FileId,
    item: u32,
    target: Declaration,
    /// Points into the value of `FileDecls`
    doc: ?[]const u8,
};
pub const ExportIndex = struct {
    arena: std.heap.ArenaAllocator.State,
    /// Sorted by name (`orderName`)
    decls: []const Export,
    /// Exports whose paths have at most `shallow_depth` segments (indices into `decls`):
    /// completion fuzzy-matches their full paths
    shallow: []const u32,
    /// Exports whose names start with `prefix` (case-insensitive)
    pub fn matching(index: *const ExportIndex, prefix: []const u8) []const Export {
        const start = prefixStart(Export, index.decls, prefix);
        var end = start;
        while (end < index.decls.len and std.ascii.startsWithIgnoreCase(index.decls[end].name, prefix)) : (end += 1) {}
        return index.decls[start..end];
    }
};

/// Traverses only real public member edges, so relative paths to a dependency's internal files
/// do not leak into the calling module.
/// Each namespace takes its shortest public path, which both terminates self-references and
/// avoids exponential path expansion through aliases.
pub const Exports = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { ns: Namespace };
    pub const Value = *const ExportIndex;
    /// Every opened file has namespaces its aliases point to, so without eviction the closures
    /// would grow with the session; evicted ones are expanded again from the never-evicted
    /// `FileDecls` and `FileLinks`, which takes only lookups and copying
    pub const lru = 1024;
    pub const lru_bytes = 16 * 1024 * 1024;
    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const Pending = struct { ns: Namespace, path: []const u8, depth: u32 };
        var queue: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(Namespace, void) = .empty;
        try queue.append(temp, .{ .ns = key.ns, .path = "", .depth = 0 });
        try seen.put(temp, key.ns, {});
        var out: std.ArrayList(Export) = .empty;
        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            const current = queue.items[i];
            const index = try ctx.get(FileDecls, current.ns.file);
            const links = try ctx.get(FileLinks, current.ns.file);
            for (index.containerMembers(current.ns.container)) |d| {
                const decl = &index.decls[d];
                if (!decl.is_pub) continue;
                const path = try appendName(a, current.path, decl.name);
                try out.append(temp, .{
                    .name = decl.name,
                    .path = path,
                    .depth = current.depth + 1,
                    .kind = decl.kind,
                    .is_extern = decl.is_extern,
                    .file = current.ns.file,
                    .item = decl.item,
                    .target = links.targets[d],
                    .doc = decl.doc,
                });
                const ns = links.namespaces[d] orelse continue;
                const entry = try seen.getOrPut(temp, ns);
                if (!entry.found_existing) try queue.append(temp, .{ .ns = ns, .path = path, .depth = current.depth + 1 });
            }
        }
        std.mem.sort(Export, out.items, {}, nameLess(Export));
        const decls = try a.dupe(Export, out.items);
        var shallow: std.ArrayList(u32) = .empty;
        for (decls, 0..) |d, j| if (d.depth <= shallow_depth) try shallow.append(temp, @intCast(j));
        const shallow_decls = try a.dupe(u32, shallow.items);
        const index = try gpa.create(ExportIndex);
        index.* = .{ .arena = arena.state, .decls = decls, .shallow = shallow_decls };
        return index;
    }
    /// Names and docs point into the value of `FileDecls` and are compared by pointer: equal only
    /// when they come from the same value. A replaced old value may already be freed, so its
    /// contents must not be read.
    pub fn eql(a: Value, b: Value) bool {
        if (a.decls.len != b.decls.len) return false;
        for (a.decls, b.decls) |x, y| {
            if (!sameSlice(x.name, y.name)) return false;
            if ((x.doc == null) != (y.doc == null) or (x.doc != null and !sameSlice(x.doc.?, y.doc.?))) return false;
            if (!std.mem.eql(u8, x.path, y.path) or x.depth != y.depth or x.kind != y.kind or x.is_extern != y.is_extern) return false;
            if (x.file != y.file or x.item != y.item or !deepEql(x.target, y.target)) return false;
        }
        return true;
    }
    pub fn bytes(v: Value) usize {
        return @sizeOf(ExportIndex) + mem.arenaBytes(v.arena);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        var arena = v.*.arena.promote(gpa);
        arena.deinit();
        gpa.destroy(@constCast(v.*));
    }
};

fn sameSlice(a: []const u8, b: []const u8) bool {
    return a.ptr == b.ptr and a.len == b.len;
}

/// The member at the cursor: passed in when the caller has already looked it up, to avoid walking
/// the file's members again
pub const Owner = union(enum) { unknown, known: ?u32 };

/// Weights of candidate sources (see `Candidate.score`): candidates accessed through a name
/// visible at the cursor (members of a namespace alias, reused direct aliases, private chains in
/// the same file) rank above those that need a new import
pub const visible_weight = 0.85;
pub const import_weight = 0.75;
/// Match score of a candidate found only by name prefix whose full path does not fuzzy-match
/// (when the name contains escaped characters)
const min_match = 0.01;

/// Each additional segment in a candidate's path reduces the factor the score is multiplied by
/// by `depth_step` (to no less than `min_depth_factor`): among equal matches, shallower ones come
/// first
const depth_step = 0.05;
const min_depth_factor = 0.5;

/// `import_options` determines where new imports are inserted (see `organize_imports.Inserter`).
/// Candidates are first sorted by score (see `Candidate.score`), then built in order (checking
/// visibility, generating the import edit) until `limit` have been built; the results keep this
/// order.
pub fn complete(r: *Resolver, file: FileId, offset: u32, owner: Owner, prefix: []const u8, limit: usize, import_options: organize_imports.Options) resolve.Error!Result {
    if (prefix.len == 0 or !isZigSource(r.ctx.db.env.vfs.path(file))) return .{ .items = &.{} };
    const current = try r.ctx.get(FileDecls, file);
    var builder: Builder = .{ .r = r, .file = file, .offset = offset, .prefix = prefix, .current = current, .matcher = try .init(r.arena, prefix), .import_options = import_options };
    const links = try r.ctx.get(FileLinks, file);
    const graph = try r.ctx.get(database.ModuleGraph.Input, {});
    builder.owner = switch (owner) {
        .unknown => try r.ownerAt(file, offset, true),
        .known => |item| item,
    };
    if (builder.owner) |item| {
        builder.body = try r.body(file, item);
        // The member's start comes from the syntax tree (recomputed on keystrokes anyway)
        // instead of `ItemSummaries`, which would have to be recomputed for the whole file
        const base = if (try r.itemNode(file, item)) |node| node.offset else offset;
        builder.scope = builder.body.?.scopeAt((offset -| base) -| 1);
    }
    // A top-level const may be an alias; whether it is visible at the cursor is checked only when
    // it is used. Consts of the enclosing containers and local constants of the member at the
    // cursor are aliases too.
    var aliases: std.ArrayList(Alias) = .empty;
    for (current.decls, links.namespaces, links.targets) |*decl, ns, target| {
        if (decl.container != 0 or decl.kind != .@"const") continue;
        try aliases.append(r.arena, .{ .name = decl.name, .def = .{ .item = .{ .file = file, .item = decl.item } }, .ns = ns, .target = target });
    }
    if (builder.owner) |item| try builder.innerAliases(item, &aliases);
    for (aliases.items) |alias| {
        if (alias.ns) |n| try builder.alias_namespaces.put(r.arena, n, {});
        if (alias.target) |target| if (!deepEql(resolve.Def{ .item = .{ .file = target.file, .item = target.item } }, alias.def)) try builder.alias_targets.put(r.arena, target, {});
    }
    builder.aliases = aliases.items;
    const matches = current.matching(prefix);
    // Existing namespace aliases take precedence; no additional import is generated for the
    // same entry. Shallow exports are fuzzy-matched by their full path, deeper ones by name
    // prefix.
    for (aliases.items) |*alias| {
        const ns = alias.ns orelse continue;
        const exports = try r.ctx.get(Exports, .{ .ns = ns });
        const declared_matches = exports.matching(prefix);
        if (exports.shallow.len == 0 and declared_matches.len == 0 and (ns.file != file or matches.start == matches.end)) continue;
        if (!try builder.refersToSelf(alias)) continue;
        const root = try renderName(r.arena, alias.name);
        for (exports.shallow) |j| try builder.member(root, &exports.decls[j], false);
        for (declared_matches) |*declared| if (declared.depth > shallow_depth) try builder.member(root, declared, true);
        // Private members are accessible within the same file; the public closure is still
        // shared by all requests.
        if (ns.file == file) for (current.decls[matches.start..matches.end], links.targets[matches.start..matches.end]) |*nested, target| {
            const relative = localRelative(current, ns, nested.*);
            const parts: Parts = if (relative) |rel| .{ root, rel } else .{ nested.path, "" };
            const score = try builder.byNameScore(parts);
            if (try builder.reuse(target, nested.name, nested.kind, nested.doc, score, parts)) continue;
            if (relative == null) continue;
            try builder.reused.put(r.arena, target, {});
            try builder.push(.{ .score = score * visible_weight, .parts = parts, .what = .{ .member = .{ .name = nested.name, .kind = nested.kind, .doc = nested.doc, .decl = .{ .file = file, .item = nested.item } } } });
        };
    }
    // Private chains within the same file are legal; visible top-level names are left to regular
    // completion.
    for (current.decls[matches.start..matches.end], links.targets[matches.start..matches.end]) |*decl, target| {
        const parts: Parts = .{ decl.path, "" };
        const score = try builder.byNameScore(parts);
        if (try builder.reuse(target, decl.name, decl.kind, decl.doc, score, parts)) continue;
        const root_name = decl.root orelse continue;
        try builder.push(.{ .score = score * visible_weight, .parts = parts, .what = .{ .chain = .{ .decl = decl, .root = root_name } } });
    }
    if (graph) |g| {
        // Module names can be completed even when they have no declarations; not offered while
        // the root is a generated file whose path is unknown.
        const names = try g.importNames(r.arena, file);
        for ([_][]const []const u8{ &.{ "std", "builtin" }, names }) |group| for (group) |name| {
            const target = g.importTarget(file, name) orelse continue;
            const ns: Namespace = .{ .file = target, .container = 0 };
            const spec = try r.arena.dupe(u8, name);
            if (try builder.matcher.score(name)) |score| if (try builder.namespaceAlias(ns) == null and try builder.visible(name) == null)
                try builder.push(.{ .score = score * import_weight, .parts = .{ spec, "" }, .what = .{ .module = .{ .name = spec, .kind = .module, .spec = spec, .target = target } } });
            try builder.exported(ns, spec);
        };
        // `root` (the root module of the compilation) is offered as a module; its declarations
        // are offered through the file itself (below) when it can be imported by path
        if (g.importTarget(file, "root")) |target| if (target != file) if (try builder.matcher.score("root")) |score| {
            if (try builder.namespaceAlias(.{ .file = target, .container = 0 }) == null and try builder.visible("root") == null)
                try builder.push(.{ .score = score * import_weight, .parts = .{ "root", "" }, .what = .{ .module = .{ .name = "root", .kind = .module, .spec = "root", .target = target } } });
        };
        // For project files, only the prefix range of the small index is queried; ItemTree/Body
        // are not scanned on the keystroke path. Files used only by tests are imported only in
        // test code (files likewise used only by tests, test declarations).
        const test_only = try r.ctx.get(TestOnlyFiles, {});
        const in_test = TestOnlyFiles.contains(test_only, file) or
            (if (builder.owner) |item| (try r.itemTree(file)).items[item].kind == .@"test" else false);
        if (g.entry(file) != null) {
            for (g.files) |entry| {
                if (entry.file == file or entry.module == database.ModuleGraph.std_module) continue;
                if (!in_test and TestOnlyFiles.contains(test_only, entry.file)) continue;
                try builder.projectFile(g, entry.file);
            }
        } else if (!inStd(r, g, file)) {
            // A file in no module (a single-file root, or a build script while the build graph
            // lacks it) is the root of its own module, made of the files it reaches through
            // relative imports (outside test code, only through imports not used only by tests)
            const reached = try TestOnlyFiles.reach(r, r.arena, &.{file}, in_test);
            for (reached.keys()) |target| if (target != file) try builder.projectFile(g, target);
        }
    }
    std.mem.sort(Found, builder.found.items, {}, foundLess);
    for (builder.found.items) |p| {
        if (builder.items.items.len >= limit) {
            builder.incomplete = true;
            break;
        }
        try builder.construct(p);
    }
    for (builder.items.items) |*item| {
        item.filter = try r.arena.dupe(u8, item.filter);
        if (item.doc) |doc| item.doc = try r.arena.dupe(u8, doc);
    }
    return .{ .items = builder.items.items, .is_incomplete = builder.incomplete };
}

/// A const that may be an alias: a top-level one of the current file, one of a container
/// enclosing the cursor, or a local constant of the member at the cursor. `def` is what its name
/// refers to where it is not shadowed; `target` is its canonical target (null for local
/// constants, which are only reused as namespaces).
const Alias = struct { name: []const u8, def: resolve.Def, ns: ?Namespace, target: ?Declaration };

/// Path of a candidate: the two parts joined by `.` (only the first part when the second is
/// empty); both scoring and the order among equal scores use it
const Parts = [2][]const u8;

/// A matched candidate that is not built yet: visibility is checked, and the label and the
/// import edit are generated, only when it is built
const Found = struct {
    score: f32,
    parts: Parts,
    /// The name starts with the input in the same case: preferred among equal scores (an
    /// all-lowercase input is scored case-insensitively)
    case_exact: bool = false,
    what: union(enum) {
        /// Accessed through a visible namespace; the label is the path
        member: struct { name: []const u8, kind: ItemTree.Item.Kind, doc: ?[]const u8, decl: Declaration },
        /// Reuses a direct alias to the same canonical target
        reuse: struct { alias: *const Alias, name: []const u8, kind: ItemTree.Item.Kind, doc: ?[]const u8 },
        /// A private chain in the same file; the label is the declaration's path
        chain: struct { decl: *const Decl, root: []const u8 },
        /// A newly imported module or file
        module: struct { name: []const u8, kind: @FieldType(Candidate, "kind"), spec: []const u8, target: FileId },
        /// A newly imported declaration
        import: struct { name: []const u8, kind: ItemTree.Item.Kind, is_extern: bool, spec: []const u8, path: []const u8, doc: ?[]const u8, target: Target },
    },
};

const Builder = struct {
    r: *Resolver,
    file: FileId,
    offset: u32,
    prefix: []const u8,
    current: *const DeclIndex,
    matcher: fuzzy.Matcher,
    owner: ?u32 = null,
    body: ?*const Body = null,
    scope: Body.ScopeId = .root,
    /// Aliases of the current file: the top-level consts, then those visible at the cursor only
    /// (see `Alias`)
    aliases: []const Alias = &.{},
    /// Namespaces of the entries in `aliases` and their canonical targets other than themselves:
    /// when something is not among them, the entries need not be checked one by one
    alias_namespaces: std.AutoHashMapUnmanaged(Namespace, void) = .empty,
    alias_targets: std.AutoHashMapUnmanaged(Declaration, void) = .empty,
    reused: std.AutoHashMapUnmanaged(Declaration, void) = .empty,
    visible_names: std.StringHashMapUnmanaged(?resolve.Def) = .empty,
    found: std.ArrayList(Found) = .empty,
    items: std.ArrayList(Candidate) = .empty,
    incomplete: bool = false,
    /// Ordering rules for import declarations (by which a new import is placed where it belongs
    /// in the organized block)
    import_options: organize_imports.Options = .{},
    /// Prepared when the first import edit is generated
    inserter: ?organize_imports.Inserter = null,
    /// The name being typed before the cursor: a candidate whose insertion edit overlaps it is
    /// not offered
    typing: ?@import("../syntax/tree.zig").TextRange = null,

    fn visible(b: *Builder, name: []const u8) resolve.Error!?resolve.Def {
        if (b.visible_names.get(name)) |result| return result;
        var found: ?resolve.Def = null;
        if (b.owner) |owner| {
            if (b.body.?.lookup(b.scope, name)) |binding| {
                found = .{ .local = .{ .file = b.file, .item = owner, .binding = binding } };
            } else if ((try b.r.itemTree(b.file)).items[owner].container != 0) {
                found = try b.r.resolveContainerName(b.file, owner, name);
            }
        }
        if (found == null) {
            if (findRoot(b.current, name)) |decl| found = .{ .item = .{ .file = b.file, .item = decl.item } };
        }
        try b.visible_names.put(b.r.arena, name, found);
        return found;
    }

    /// No coarse filtering by the current file's `FileIndex` first: when typing character by
    /// character, completion comes right after each edit, so `FileIndex` always has to be
    /// recomputed, which is more expensive than `BindingNames`
    fn bindingConflict(b: *Builder, name: []const u8) resolve.Error!bool {
        return BindingNames.contains(try b.r.ctx.get(BindingNames, b.file), name);
    }
    /// Appends the consts of the containers enclosing member `owner` (other than the file root)
    /// and the local constants that refer to a namespace in scope at the cursor
    fn innerAliases(b: *Builder, owner: u32, out: *std.ArrayList(Alias)) resolve.Error!void {
        const r = b.r;
        const tree = try r.itemTree(b.file);
        var container = tree.items[owner].container;
        while (container != 0) {
            for (tree.containerMembers(container)) |m| {
                const it = tree.items[m];
                if (it.kind != .@"const") continue;
                const key = try r.ownerKey(b.file, m);
                try out.append(r.arena, .{ .name = it.name orelse continue, .def = .{ .item = .{ .file = b.file, .item = m } }, .ns = try r.ctx.get(DeclNamespace, key), .target = try r.ctx.get(DeclTarget, key) });
            }
            const parent = tree.containers[container].parent_item orelse break;
            container = tree.items[parent].container;
        }
        const body = b.body.?;
        var s: ?Body.ScopeId = b.scope;
        while (s) |id| : (s = body.scope(id).parent) for (body.scope(id).bindings) |binding_id| {
            const binding = body.binding(binding_id);
            if (binding.kind != .local_const) continue;
            const ns = try r.evalNamespace(b.file, owner, body, binding.init orelse continue) orelse continue;
            try out.append(r.arena, .{ .name = binding.name, .def = .{ .local = .{ .file = b.file, .item = owner, .binding = binding_id } }, .ns = ns, .target = null });
        };
    }
    /// The alias's name refers to the alias itself at the cursor (it is in scope and not
    /// shadowed)
    fn refersToSelf(b: *Builder, alias: *const Alias) resolve.Error!bool {
        const def = try b.visible(alias.name) orelse return false;
        return deepEql(def, alias.def);
    }
    /// The first alias visible at the cursor that refers to `ns`
    fn namespaceAlias(b: *Builder, ns: Namespace) resolve.Error!?*const Alias {
        if (!b.alias_namespaces.contains(ns)) return null;
        for (b.aliases) |*alias| if (alias.ns) |n| if (deepEql(n, ns) and try b.refersToSelf(alias)) return alias;
        return null;
    }
    /// The first direct alias visible at the cursor whose canonical target is `target`
    fn directAlias(b: *Builder, target: Declaration) resolve.Error!?*const Alias {
        if (!b.alias_targets.contains(target)) return null;
        for (b.aliases) |*alias| if (alias.target) |t| {
            if (deepEql(t, target) and !deepEql(resolve.Def{ .item = .{ .file = t.file, .item = t.item } }, alias.def) and try b.refersToSelf(alias)) return alias;
        };
        return null;
    }
    /// Reuses a direct alias visible for the canonical target instead, when there is one (`score`
    /// is the match score of the path `parts`)
    fn reuse(b: *Builder, target: Declaration, name: []const u8, kind: ItemTree.Item.Kind, doc: ?[]const u8, score: f32, parts: Parts) resolve.Error!bool {
        const alias = try b.directAlias(target) orelse return false;
        // When the alias and the target share the prefix, the filter name must be chosen again
        // after further typing; the other spelling cannot be kept.
        if (!std.mem.eql(u8, alias.name, name) and std.ascii.startsWithIgnoreCase(alias.name, b.prefix)) b.incomplete = true;
        try b.push(.{ .score = score * visible_weight, .parts = parts, .what = .{ .reuse = .{ .alias = alias, .name = name, .kind = kind, .doc = doc } } });
        try b.reused.put(b.r.arena, target, {});
        return true;
    }
    /// The export `declared` of the visible namespace alias `root`; with `by_name`, it has already
    /// matched by name prefix
    fn member(b: *Builder, root: []const u8, declared: *const Export, by_name: bool) resolve.Error!void {
        const parts: Parts = .{ root, declared.path };
        const score = try b.matchOf(parts, by_name) orelse return;
        if (try b.reuse(declared.target, declared.name, declared.kind, declared.doc, score, parts)) return;
        try b.reused.put(b.r.arena, declared.target, {});
        try b.push(.{ .score = score * visible_weight, .parts = parts, .what = .{ .member = .{ .name = declared.name, .kind = declared.kind, .doc = declared.doc, .decl = .{ .file = declared.file, .item = declared.item } } } });
    }
    fn exported(b: *Builder, ns: Namespace, spec: []const u8) resolve.Error!void {
        if (try b.namespaceAlias(ns) != null) return;
        const index = try b.r.ctx.get(Exports, .{ .ns = ns });
        for (index.shallow) |j| try b.exportedDecl(&index.decls[j], spec, false);
        for (index.matching(b.prefix)) |*decl| if (decl.depth > shallow_depth) try b.exportedDecl(decl, spec, true);
    }
    fn exportedDecl(b: *Builder, decl: *const Export, spec: []const u8, by_name: bool) resolve.Error!void {
        const parts: Parts = .{ spec, decl.path };
        const score = try b.matchOf(parts, by_name) orelse return;
        if (try b.reuse(decl.target, decl.name, decl.kind, decl.doc, score, parts)) return;
        if (b.reused.contains(decl.target)) return;
        try b.push(.{ .score = score * import_weight, .parts = parts, .what = .{ .import = .{ .name = decl.name, .kind = decl.kind, .is_extern = decl.is_extern, .spec = spec, .path = decl.path, .doc = decl.doc, .target = .{ .decl = .{ .file = decl.file, .item = decl.item } } } } });
    }
    /// The project file `file` and its public declarations, imported by relative path
    fn projectFile(b: *Builder, g: *const database.ModuleGraph, file: FileId) resolve.Error!void {
        const r = b.r;
        const path = r.ctx.db.env.vfs.path(file);
        if (!isZigSource(path)) return;
        const index = try r.ctx.get(FileDecls, file);
        const public = index.matchingPublic(b.prefix);
        const basename = std.fs.path.basename(path);
        const stem = basename[0 .. basename.len - ".zig".len];
        const stem_score = try b.matcher.score(stem);
        if (public.len == 0 and stem_score == null) return;
        const spec = try importSpec(r, g, b.file, file) orelse return;
        // A module root imported by its name is offered under that name, with its exports,
        // above; its file name (often `root`) is no name for it
        if (g.importTarget(b.file, spec) == file) return;
        const ns: Namespace = .{ .file = file, .container = 0 };
        const aliased = try b.namespaceAlias(ns) != null;
        if (stem_score) |score| if (!aliased and try b.visible(stem) == null)
            try b.push(.{ .score = score * import_weight, .parts = .{ stem, "" }, .what = .{ .module = .{ .name = stem, .kind = .file, .spec = spec, .target = file } } });
        if (aliased or public.len == 0) return;
        const targets = (try r.ctx.get(FileLinks, file)).targets;
        for (public) |p| {
            const decl = &index.decls[p.decl];
            const target = targets[p.decl];
            const parts: Parts = .{ stem, p.path };
            const score = try b.byNameScore(parts);
            if (try b.reuse(target, decl.name, decl.kind, decl.doc, score, parts)) continue;
            if (b.reused.contains(target)) continue;
            try b.push(.{ .score = score * import_weight, .parts = parts, .what = .{ .import = .{ .name = decl.name, .kind = decl.kind, .is_extern = decl.is_extern, .spec = spec, .path = p.path, .doc = decl.doc, .target = .{ .decl = .{ .file = file, .item = decl.item } } } } });
        }
    }
    /// The match score of the path multiplied by the depth factor; null when it does not match.
    /// With `by_name`, the candidate has already matched by name prefix, and when its path does not
    /// match (the name contains escaped characters), the minimum score is used
    fn matchOf(b: *Builder, parts: Parts, by_name: bool) resolve.Error!?f32 {
        const score = try b.matcher.scoreJoined(&joined(parts)) orelse
            (if (by_name) min_match else return null);
        return score * depthFactor(parts);
    }
    /// Score of a candidate that has already matched by name prefix (see `matchOf`)
    fn byNameScore(b: *Builder, parts: Parts) resolve.Error!f32 {
        return (try b.matchOf(parts, true)).?;
    }
    fn push(b: *Builder, p: Found) resolve.Error!void {
        var found = p;
        const name = switch (p.what) {
            .member => |m| m.name,
            .reuse => |u| u.name,
            .chain => |c| c.decl.name,
            .module => |m| m.name,
            .import => |i| i.name,
        };
        found.case_exact = std.mem.startsWith(u8, name, b.prefix);
        try b.found.append(b.r.arena, found);
    }
    /// Filters by name when the name starts with the typed prefix; a candidate matched by path is
    /// filtered by its path, so the client does not filter it out
    fn filterOf(b: *Builder, name: []const u8, parts: Parts) resolve.Error![]const u8 {
        if (std.ascii.startsWithIgnoreCase(name, b.prefix)) return name;
        return joinPath(b.r.arena, parts[0], parts[1]);
    }
    fn construct(b: *Builder, p: Found) resolve.Error!void {
        switch (p.what) {
            .member => |m| {
                if (try b.visible(m.name) != null) return;
                try b.add(.{ .label = try joinPath(b.r.arena, p.parts[0], p.parts[1]), .kind = try b.declKind(m.decl), .filter = try b.filterOf(m.name, p.parts), .qualifier = p.parts[0], .score = p.score, .doc = m.doc, .target = .{ .decl = m.decl } });
            },
            .reuse => |u| {
                // Only aliases with a canonical target, all of which are declarations, are reused
                const alias: Declaration = .{ .file = b.file, .item = u.alias.def.item.item };
                try b.add(.{ .label = try renderName(b.r.arena, u.alias.name), .kind = try b.declKind(alias), .filter = try b.filterOf(u.name, p.parts), .qualifier = "", .score = p.score, .doc = u.doc, .target = .{ .decl = alias } });
            },
            .chain => |c| {
                if (try b.visible(c.decl.name) != null) return;
                const root_def = try b.visible(c.root) orelse return;
                const expected = findRoot(b.current, c.root) orelse return;
                if (!deepEql(root_def, resolve.Def{ .item = .{ .file = b.file, .item = expected.item } })) return;
                try b.add(.{ .label = try b.r.arena.dupe(u8, c.decl.path), .kind = try b.declKind(.{ .file = b.file, .item = c.decl.item }), .filter = try b.filterOf(c.decl.name, p.parts), .qualifier = try renderName(b.r.arena, c.root), .score = p.score, .doc = c.decl.doc, .target = .{ .decl = .{ .file = b.file, .item = c.decl.item } } });
            },
            .module => |m| try b.importCandidate(m.name, m.kind, false, m.spec, "", null, p, .{ .file = m.target }),
            .import => |i| {
                if (try b.visible(i.name) != null) return;
                // Runtime storage (container-level vars, extern consts) cannot be copied into a
                // new comptime constant
                const storage = i.kind == .@"var" or (i.is_extern and i.kind == .@"const");
                try b.importCandidate(i.name, try b.declKind(i.target.decl), storage, i.spec, i.path, i.doc, p, i.target);
            },
        }
    }
    fn add(b: *Builder, candidate: Candidate) resolve.Error!void {
        for (b.items.items) |existing| {
            if (std.mem.eql(u8, existing.label, candidate.label) and std.mem.eql(u8, existing.qualifier, candidate.qualifier)) return;
        }
        try b.items.append(b.r.arena, candidate);
    }
    /// Kind of a built candidate (see `symbol_kind`). First takes the resident results already
    /// computed when the index was built: functions, declarations whose kind the syntax determines
    /// (`Decl.form`), consts whose value is a namespace, and aliases to them, without parsing their
    /// file or inferring the declaration's type; for the rest, the declaration's type is inferred.
    fn declKind(b: *Builder, decl: Declaration) resolve.Error!@FieldType(Candidate, "kind") {
        const key = try b.r.ownerKey(decl.file, decl.item);
        if (try b.indexedKind(decl, key)) |kind| return kind;
        const target = try b.r.ctx.get(DeclTarget, key);
        if (!deepEql(target, decl)) if (try b.indexedKind(target, try b.r.ownerKey(target.file, target.item))) |kind| return kind;
        const symbol = try symbol_kind.ofDecl(b.r, decl.file, decl.item);
        return switch (symbol.kind) {
            .namespace => .namespace,
            .@"struct" => .@"struct",
            .@"enum" => .@"enum",
            .type => .type,
            .function, .method => .function,
            .variable, .field, .enum_member, .parameter, .type_parameter => if (symbol.readonly) .constant else .variable,
        };
    }
    /// Kind of functions (auto-import does not offer methods; see `DeclBuilder.isMethod`), of
    /// consts and vars whose kind the syntax determines, and of consts whose value is a Zig file
    /// or a container
    fn indexedKind(b: *Builder, decl: Declaration, key: hir.OwnerKey) resolve.Error!?@FieldType(Candidate, "kind") {
        const item_kind = (try b.r.itemTree(decl.file)).items[decl.item].kind;
        switch (item_kind) {
            .@"fn" => return .function,
            .@"const", .@"var" => {},
            else => return null,
        }
        if ((try b.r.ctx.get(FileDecls, decl.file)).byItem(decl.item)) |d| switch (d.form) {
            .value => return if (item_kind == .@"var") .variable else .constant,
            .type => return .type,
            .function => return .function,
            .unknown => {},
        };
        if (item_kind != .@"const") return null;
        const ns = try b.r.ctx.get(DeclNamespace, key) orelse return null;
        if (!isZigSource(b.r.ctx.db.env.vfs.path(ns.file))) return null;
        const tree = try b.r.itemTree(ns.file);
        return switch (tree.containers[ns.container].kind) {
            .file => if (tree.hasFields(ns.container)) .@"struct" else .namespace,
            .@"struct" => .@"struct",
            .@"enum" => .@"enum",
            .@"union", .@"opaque" => .type,
        };
    }
    fn importCandidate(b: *Builder, name: []const u8, kind: @FieldType(Candidate, "kind"), storage: bool, spec: []const u8, path: []const u8, doc: ?[]const u8, p: Found, target: Target) resolve.Error!void {
        const a = b.r.arena;
        const qualifier = if (path.len == 0) spec else try std.fmt.allocPrint(a, "{s}:{s}", .{ spec, path });
        var binding = name;
        var binding_path = path;
        var direct = false;
        // Runtime storage is accessed through the namespace; an extern const still keeps the
        // read-only completion kind.
        const label = if (storage or try b.bindingConflict(name)) blk: {
            const base = std.fs.path.basename(spec);
            const namespace = if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base;
            if (try b.bindingConflict(namespace) or try b.visible(namespace) != null) {
                direct = true;
                break :blk try std.fmt.allocPrint(a, "@import(\"{f}\"){s}{s}", .{
                    std.zig.fmtString(spec), if (path.len == 0) "" else ".", path,
                });
            }
            binding = namespace;
            binding_path = "";
            break :blk if (path.len == 0) try renderName(a, namespace) else try std.fmt.allocPrint(a, "{f}.{s}", .{ std.zig.fmtId(namespace), path });
        } else try renderName(a, name);
        const edit: ?Edit = if (direct) null else blk: {
            if (b.inserter == null) {
                const parse = try b.r.ctx.get(database.syntax.ParseFile, b.file);
                b.inserter = try organize_imports.Inserter.init(a, parse, b.import_options);
                if (parse.rootNode().tokenAtOffset(b.offset -| 1)) |token| if (token.kind == .identifier or token.kind == .invalid) {
                    b.typing = token.range();
                };
            }
            const decl = try std.fmt.allocPrint(a, "const {f} = @import(\"{f}\"){s}{s};", .{
                std.zig.fmtId(binding), std.zig.fmtString(spec), if (binding_path.len == 0) "" else ".", binding_path,
            });
            const e = try b.inserter.?.edit(a, binding, spec, binding_path, decl);
            if (b.typing) |t| if (e.start < t.end and @max(e.end, e.start + 1) > t.start) return;
            break :blk .{ .start = e.start, .end = e.end, .text = e.text };
        };
        try b.add(.{ .label = label, .kind = kind, .filter = try b.filterOf(name, p.parts), .qualifier = qualifier, .score = p.score, .doc = doc, .import_edit = edit, .target = target });
    }
};

/// Each additional segment in the path reduces the factor by `depth_step`
fn depthFactor(parts: Parts) f32 {
    var segments: usize = 1 + std.mem.count(u8, parts[0], ".");
    if (parts[1].len != 0) segments += 1 + std.mem.count(u8, parts[1], ".");
    return segmentFactor(segments);
}

/// Depth factor of a path with `segments` segments (see `depth_step`)
pub fn segmentFactor(segments: usize) f32 {
    return @max(min_depth_factor, 1 - depth_step * @as(f32, @floatFromInt(segments - 1)));
}

/// By score from high to low; among equal scores, names whose case matches the input come first,
/// then by path and source
fn foundLess(_: void, a: Found, b: Found) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.case_exact != b.case_exact) return a.case_exact;
    const order = orderParts(a.parts, b.parts);
    if (order != .eq) return order == .lt;
    return @backingInt(a.what) < @backingInt(b.what);
}

/// Compares two paths, each concatenated in order (for the `.` in between, see `Parts`)
fn orderParts(a: Parts, b: Parts) std.math.Order {
    const x = joined(a);
    const y = joined(b);
    var k: usize = 0;
    while (true) : (k += 1) {
        const p = byteAt(x, k) orelse return if (byteAt(y, k) == null) .eq else .lt;
        const q = byteAt(y, k) orelse return .gt;
        if (p != q) return std.math.order(p, q);
    }
}

fn joined(parts: Parts) [3][]const u8 {
    return .{ parts[0], if (parts[1].len == 0) "" else ".", parts[1] };
}

fn byteAt(parts: [3][]const u8, k: usize) ?u8 {
    var i = k;
    for (parts) |part| {
        if (i < part.len) return part[i];
        i -= part.len;
    }
    return null;
}

/// The file is in the standard library of its compilation
fn inStd(r: *Resolver, graph: *const database.ModuleGraph, file: FileId) bool {
    const vfs = r.ctx.db.env.vfs;
    const root = graph.contextImport(file, graph.home(file), "std") orelse return false;
    const dir = std.fs.path.dirname(vfs.path(root)) orelse return false;
    return vfs.isUnder(vfs.path(file), dir);
}

fn importSpec(r: *Resolver, graph: *const database.ModuleGraph, from: FileId, target: FileId) resolve.Error!?[]const u8 {
    for ([_][]const u8{ "std", "builtin" }) |name| if (graph.importTarget(from, name) == target) return name;
    for (try graph.importNames(r.arena, from)) |name| if (graph.importTarget(from, name) == target) return try r.arena.dupe(u8, name);
    const vfs = r.ctx.db.env.vfs;
    // A file in no module (a single-file root, or a build script while the build graph lacks it)
    // is the root of its own module
    const root = if (graph.entry(from)) |src| blk: {
        const dst = graph.entry(target) orelse return null;
        if (src.module != dst.module or src.module == database.ModuleGraph.std_module) return null;
        break :blk graph.modules[src.module].root orelse return null;
    } else from;
    const root_dir = std.fs.path.dirname(vfs.path(root)) orelse return null;
    const target_path = vfs.path(target);
    if (!vfs.isUnder(vfs.path(from), root_dir) or !vfs.isUnder(target_path, root_dir)) return null;
    const dir = std.fs.path.dirname(vfs.path(from)) orelse return null;
    const relative = try std.fs.path.relativeAlloc(r.arena, root_dir, null, dir, target_path);
    for (relative) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return relative;
}

/// The path or module name the current file uses to import `target`; null when it cannot be
/// imported directly
pub fn importPath(r: *Resolver, from: FileId, target: FileId) resolve.Error!?[]const u8 {
    const graph = try r.ctx.get(database.ModuleGraph.Input, {}) orelse return null;
    return importSpec(r, graph, from, target);
}

/// Display path of the file containing a definition: in the standard library, the path under
/// `std/`; for a file the current file can import by path, the import path; under the root
/// directory of another module the current file can import, the module name plus the path under
/// the root directory (the module root is not necessarily in the compile set); otherwise the
/// full path
pub fn displayPath(r: *Resolver, from: FileId, target: FileId) resolve.Error![]const u8 {
    const vfs = r.ctx.db.env.vfs;
    const path = vfs.path(target);
    const graph = try r.ctx.get(database.ModuleGraph.Input, {}) orelse return path;
    if (graph.std_root) |root| if (std.fs.path.dirname(vfs.path(root))) |dir| if (vfs.isUnder(path, dir))
        return under(r.arena, "std", dir, path);
    if (try importSpec(r, graph, from, target)) |spec| if (isZigSource(spec)) return spec;
    for ([_][]const []const u8{ &.{"builtin"}, try graph.importNames(r.arena, from) }) |group| for (group) |name| {
        const root = graph.importTarget(from, name) orelse continue;
        const dir = std.fs.path.dirname(vfs.path(root)) orelse continue;
        if (vfs.isUnder(path, dir)) return under(r.arena, name, dir, path);
    };
    return path;
}

/// The part of `path` relative to `dir`, prefixed with `prefix/`, with separators normalized
/// to `/`
fn under(a: Allocator, prefix: []const u8, dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
    const relative = try std.fs.path.relativeAlloc(a, dir, null, dir, path);
    for (relative) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, relative });
}

fn findRoot(index: *const DeclIndex, name: []const u8) ?Decl {
    const start = lowerBound(Decl, index.decls, name);
    for (index.decls[start..]) |decl| {
        if (!std.mem.eql(u8, decl.name, name)) break;
        if (decl.container == 0) return decl;
    }
    return null;
}
/// Path of `decl` relative to namespace `ns` in the same file; lexical paths of containers are
/// precomputed, so each lookup is O(1)
fn localRelative(index: *const DeclIndex, ns: Namespace, decl: Decl) ?[]const u8 {
    if (ns.container == 0) return decl.path;
    if (ns.container >= index.container_paths.len) return null;
    const prefix = index.container_paths[ns.container] orelse return null;
    if (prefix.len == 0) return decl.path;
    if (decl.path.len <= prefix.len or !std.mem.startsWith(u8, decl.path, prefix) or decl.path[prefix.len] != '.') return null;
    return decl.path[prefix.len + 1 ..];
}
fn renderName(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{f}", .{std.zig.fmtId(name)});
}
fn appendName(a: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return joinPath(a, path, try renderName(a, name));
}
fn joinPath(a: Allocator, lhs: []const u8, rhs: []const u8) Allocator.Error![]const u8 {
    if (lhs.len == 0) return a.dupe(u8, rhs);
    return std.fmt.allocPrint(a, "{s}.{s}", .{ lhs, rhs });
}
/// Order of names in the indexes: ASCII case-insensitive first, then by bytes on ties. Names that
/// start with the same prefix case-insensitively are therefore contiguous and can be binary
/// searched; exact lookup by name uses the same order.
fn orderName(a: []const u8, b: []const u8) std.math.Order {
    const order = std.ascii.orderIgnoreCase(a, b);
    return if (order != .eq) order else std.mem.order(u8, a, b);
}
fn nameLess(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn less(_: void, a: T, b: T) bool {
            const order = orderName(a.name, b.name);
            if (order != .eq) return order == .lt;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less;
}
/// The first item whose name is not less than `name` (by `orderName`)
fn lowerBound(comptime T: type, items: []const T, name: []const u8) usize {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (orderName(items[mid].name, name) == .lt) low = mid + 1 else high = mid;
    }
    return low;
}
/// The first item whose name is case-insensitively not less than `prefix`: items starting with
/// `prefix` (case-insensitive) begin here
fn prefixStart(comptime T: type, items: []const T, prefix: []const u8) usize {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (std.ascii.lessThanIgnoreCase(items[mid].name, prefix)) low = mid + 1 else high = mid;
    }
    return low;
}

test {
    _ = @import("imports_test.zig");
}
