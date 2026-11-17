//! Unused private declarations: container-level `fn`, `const` and `var` declarations without
//! `pub`, `export` or `extern` that no code in their file can reach. The compiler reports unused
//! local constants and function parameters, but never these.
//!
//! Visibility is per file: a declaration without `pub` can only be referenced from the file that
//! declares it (the compiler rejects `S.x` and `@field(S, "x")` from another file, also when the
//! container is returned from a generic function), so a file-local reference search is complete.
//! `@hasDecl` and `std.meta.declarations` see only `pub` declarations, and since Zig 0.17
//! `@typeInfo` does not list declarations at all. The only name-based reference without an
//! identifier in the file is `@field(T, "name")` and `@hasDecl(T, "name")` with a string literal,
//! which count as uses here; a `@field` whose name is computed disables the check for the file,
//! since the name could then be any declaration.
//!
//! Findings are the declarations that no reachable declaration references. Roots (live by
//! definition) are the file-scope declarations that code outside the file or the compiler can
//! reach: `pub`, `export`, `extern`, tests, `comptime` blocks and fields. Members of a nested
//! container that are part of its interface (fields, `pub`/`export`/`extern` declarations, tests
//! and `comptime` blocks) are live when the declaration that defines the container is live: a
//! test or `comptime` block of a container that is never referenced does not run. Private
//! declarations are live only when a live declaration references them, so a helper used only by
//! other unused declarations is reported too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const database = @import("../database.zig");
const Db = database.Db;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const search = @import("../ide_db/search.zig");
const ast = @import("../syntax/ast.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const tree = @import("../syntax/tree.zig");
const SyntaxNode = tree.SyntaxNode;
const TextRange = tree.TextRange;
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;

/// A declaration that no reachable code uses: the range of its name
pub const Located = struct {
    start: u32,
    end: u32,
    name: []const u8,
};

const Candidate = struct {
    item: u32,
    name: []const u8,
    node: TextRange,
    start: u32,
    end: u32,
};

const Edge = struct { from: u32, to: u32 };

/// A `@field(T, "name")` or `@hasDecl(T, "name")` with a string literal: the declaration it may
/// reference is used when the member containing the call is live
const Reflection = struct { owner: ?u32, name: []const u8 };

/// Unused private declarations in `file`, ordered by position
pub fn findings(r: *Resolver, file: FileId) resolve.Error![]const Located {
    return try r.ctx.get(Query, file);
}

/// Findings of a file: computed once per revision, and reused by every publish of the file
pub const Query = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = []const Located;

    pub fn compute(ctx: *Db.Ctx, file: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const found = try scan(&r, file);
        const gpa = ctx.db.gpa;
        const out = try gpa.alloc(Located, found.len);
        errdefer gpa.free(out);
        var copied: usize = 0;
        errdefer for (out[0..copied]) |f| gpa.free(f.name);
        for (found) |f| {
            out[copied] = .{ .start = f.start, .end = f.end, .name = try gpa.dupe(u8, f.name) };
            copied += 1;
        }
        return out;
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x.start != y.start or x.end != y.end or !std.mem.eql(u8, x.name, y.name)) return false;
        }
        return true;
    }

    pub fn bytes(v: Value) usize {
        var n = v.len * @sizeOf(Located);
        for (v) |f| n += f.name.len;
        return n;
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        for (v.*) |f| gpa.free(f.name);
        gpa.free(v.*);
    }
};

fn scan(r: *Resolver, file: FileId) resolve.Error![]const Located {
    const parse = try r.ctx.get(database.syntax.ParseFile, file);
    // References in a file with syntax errors may be missing (the tree recovered around them):
    // no finding is worth a false positive while the file is being edited
    if (parse.mode != .zig or parse.errors.len != 0) return &.{};

    const items = try r.itemTree(file);

    var reflections: std.ArrayList(Reflection) = .empty;
    var dynamic_reflection = false;
    try scanReflection(r, file, parse.rootNode(), &reflections, &dynamic_reflection);
    // `@field` with a computed name could reach any private declaration of the file
    if (dynamic_reflection) return &.{};

    var candidates: std.ArrayList(Candidate) = .empty;
    // Private declarations that are not reported (a leading underscore marks a declaration that
    // is intentionally kept, and `@"..."` names are written deliberately) are still live roots:
    // their references must keep the declarations they use alive, or those would be false
    // positives
    var kept: std.ArrayList(u32) = .empty;
    for (items.items, 0..) |item, i| {
        const index: u32 = @intCast(i);
        // A member without a node cannot be located: no finding is worth a possible reference
        // missed in it
        const node = try r.itemNode(file, index) orelse return &.{};
        if (item.name == null) continue;
        if (item.kind != .@"fn" and item.kind != .@"const" and item.kind != .@"var") continue;
        if (item.flags.is_pub or item.flags.is_export or item.flags.is_extern) continue;
        const name = item.name.?;
        const tok = ast.memberName(node, try r.inEnum(file, index)) orelse return &.{};
        if (name.len == 0 or name[0] == '_' or (tok.text.len > 0 and tok.text[0] == '@')) {
            try kept.append(r.arena, index);
            continue;
        }
        try candidates.append(r.arena, .{
            .item = index,
            .name = name,
            .node = node.range(),
            .start = tok.offset,
            .end = tok.offset + @as(u32, @intCast(tok.text.len)),
        });
    }
    if (candidates.items.len == 0) return &.{};

    var edges: std.ArrayList(Edge) = .empty;
    var roots: std.ArrayList(u32) = .empty;
    for (candidates.items) |c| {
        var ambiguous: ?search.Reference = null;
        var uncertain: ?search.Reference = null;
        var incomplete: ?search.Reference = null;
        var syntax_error: ?FileId = null;
        const refs = try search.findReferences(r, .{ .item = .{ .file = file, .item = c.item } }, .{
            .scope = &.{},
            .only_file = file,
            .ambiguous = &ambiguous,
            .uncertain = &uncertain,
            .incomplete = &incomplete,
            .syntax_error = &syntax_error,
        });
        // The file contains this name but cannot be resolved: no finding for any declaration
        if (syntax_error != null) return &.{};
        // A reference that cannot be confirmed, or one that refers to this declaration under
        // some instance or configuration, keeps it and the members that may contain the use live
        if (uncertain) |ref| if (ref.file == file) try useAt(r, file, c, ref.start, &edges, &roots);
        if (incomplete) |ref| if (ref.file == file) try useAt(r, file, c, ref.start, &edges, &roots);
        if (ambiguous) |ref| if (ref.file == file) try useAt(r, file, c, ref.start, &edges, &roots);
        for (refs) |ref| {
            if (ref.is_decl or ref.file != file) continue;
            // A reference from the declaration's own body (recursion) or from a container defined
            // in it does not make it live by itself
            if (c.node.start <= ref.start and ref.end <= c.node.end) continue;
            try useAt(r, file, c, ref.start, &edges, &roots);
        }
    }

    // A `@field`/`@hasDecl` literal names a declaration of this file
    for (reflections.items) |ref| {
        for (candidates.items) |c| {
            if (!std.mem.eql(u8, ref.name, c.name)) continue;
            if (ref.owner) |owner| {
                if (owner != c.item) try edges.append(r.arena, .{ .from = owner, .to = c.item });
            } else try roots.append(r.arena, c.item);
        }
    }

    const live = try r.arena.alloc(bool, items.items.len);
    @memset(live, false);
    var queue: std.ArrayList(u32) = .empty;
    for (items.items, 0..) |item, i| {
        const index: u32 = @intCast(i);
        if (isRoot(items, item)) {
            live[i] = true;
            try queue.append(r.arena, index);
            continue;
        }
        // A member of the interface of a nested container lives with the declaration that defines
        // the container: fields are part of its layout, and `pub`/`export`/`extern` members, tests
        // and `comptime` blocks are reachable through it
        const parent = items.containers[item.container].parent_item orelse continue;
        if (isInterface(item)) try edges.append(r.arena, .{ .from = parent, .to = index });
    }
    for (roots.items) |i| if (!live[i]) {
        live[i] = true;
        try queue.append(r.arena, i);
    };
    for (kept.items) |i| if (!live[i]) {
        live[i] = true;
        try queue.append(r.arena, i);
    };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const from = queue.items[head];
        for (edges.items) |e| {
            if (e.from != from or live[e.to]) continue;
            live[e.to] = true;
            try queue.append(r.arena, e.to);
        }
    }

    var out: std.ArrayList(Located) = .empty;
    for (candidates.items) |c| {
        if (live[c.item]) continue;
        try out.append(r.arena, .{ .start = c.start, .end = c.end, .name = c.name });
    }
    std.mem.sort(Located, out.items, {}, struct {
        fn lt(_: void, a: Located, b: Located) bool {
            return a.start < b.start;
        }
    }.lt);
    return out.items;
}

/// The use at `offset` refers to `c`: an edge from the member containing it, or a root when it is
/// outside every member
fn useAt(r: *Resolver, file: FileId, c: Candidate, offset: u32, edges: *std.ArrayList(Edge), roots: *std.ArrayList(u32)) resolve.Error!void {
    const owner = try r.ownerAt(file, offset, false);
    if (owner) |o| {
        if (o != c.item) try edges.append(r.arena, .{ .from = o, .to = c.item });
    } else try roots.append(r.arena, c.item);
}

/// Whether the declaration is reachable without a reference from this file
fn isRoot(items: *const ItemTree, item: ItemTree.Item) bool {
    // Nested declarations are reached through the declaration that defines their container
    if (items.containers[item.container].parent_item != null) return false;
    return isInterface(item);
}

/// Whether the declaration is part of the interface of its container: reachable when the
/// container is, without a reference to it by name
fn isInterface(item: ItemTree.Item) bool {
    return switch (item.kind) {
        .field, .@"test", .@"comptime" => true,
        .@"fn", .@"const", .@"var" => item.flags.is_pub or item.flags.is_export or item.flags.is_extern,
        .zon => false,
    };
}

/// Records the `@field` and `@hasDecl` calls with a string literal name, which reference a
/// declaration without spelling it with an identifier. A computed `@field` name sets
/// `dynamic`, since it could name any declaration of the file.
fn scanReflection(r: *Resolver, file: FileId, node: SyntaxNode, out: *std.ArrayList(Reflection), dynamic: *bool) resolve.Error!void {
    if (node.kind() == .builtin_call) {
        const call = ast.BuiltinCall{ .syntax = node };
        const name = call.name();
        if (name) |tok| {
            const field = std.mem.eql(u8, tok.text, "@field");
            const has_decl = std.mem.eql(u8, tok.text, "@hasDecl");
            if (field or has_decl) {
                var args = call.args();
                _ = args.next();
                if (args.next()) |arg| {
                    if (arg.childToken(.string_literal)) |lit| {
                        const decoded = std.zig.string_literal.parseAlloc(r.arena, lit.text) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.InvalidLiteral => null,
                        };
                        if (decoded) |text| try out.append(r.arena, .{
                            .owner = try r.ownerAt(file, node.offset, false),
                            .name = text,
                        });
                    } else if (field) {
                        // `@hasDecl` with a computed name can only name a `pub` declaration
                        dynamic.* = true;
                    }
                }
            }
        }
    }
    var children = node.children();
    while (children.next()) |child| switch (child) {
        .node => |n| try scanReflection(r, file, n, out, dynamic),
        .token => {},
    };
}

test {
    _ = @import("unused_test.zig");
}
