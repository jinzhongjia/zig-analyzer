//! Name resolution: local scopes → the chain of lexically enclosing containers; for `a.b.c`, the
//! namespace is evaluated along `@import`, container definitions, `@This()` and alias chains, and
//! then the member is looked up. No type inference: namespaces obtained through function calls or
//! variable types (such as `std.ArrayList(u8)`, or `x.` for `var x: S`) are handled by sema.

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const Db = database.Db;
const syntax = database.syntax;
const hir = database.hir;
const ModuleGraph = @import("ModuleGraph.zig");
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;
const ItemTree = @import("../syntax/ItemTree.zig");
const Parse = @import("../syntax/Parse.zig");
const ast = @import("../syntax/ast.zig");
const SyntaxNode = ast.SyntaxNode;
const Body = @import("../hir/Body.zig");

/// Result of name resolution
pub const Def = union(enum) {
    /// Container member (index into `ItemTree.items`)
    item: struct { file: FileId, item: u32 },
    /// Local binding: parameter, local variable or capture (`item` is the enclosing BodyOwner)
    local: struct { file: FileId, item: u32, binding: Body.BindingId },
    /// Target file of an `@import`
    file: FileId,
};

/// A namespace that supports member access: a container in a file (0 is the file itself)
pub const Namespace = struct {
    file: FileId,
    container: u32,
};

pub const Error = error{ Canceled, OutOfMemory };

/// Maximum length of an alias chain, guarding against cycles such as `const a = b; const b = a;`.
/// Same as the recursion limit for glob imports in rust-analyzer's name resolution.
const max_depth = 100;

pub const Resolver = struct {
    ctx: *Db.Ctx,
    arena: Allocator,

    fn vfs(r: *Resolver) *Vfs {
        return r.ctx.db.env.vfs;
    }

    /// `.zon` files: `@import` of one yields the value in it, not a namespace
    pub fn isZon(r: *Resolver, file: FileId) bool {
        return Parse.modeOf(r.vfs().path(file)) == .zon;
    }

    pub fn itemTree(r: *Resolver, file: FileId) Error!*const ItemTree {
        return r.ctx.get(syntax.FileItemTree, file);
    }

    pub fn ownerKey(r: *Resolver, file: FileId, item: u32) Error!hir.OwnerKey {
        return .{ .file = file, .item = (try r.itemTree(file)).items[item].ast_id };
    }

    pub fn body(r: *Resolver, file: FileId, item: u32) Error!*const Body {
        return r.ctx.get(hir.ItemBody, try r.ownerKey(file, item));
    }

    /// Member node (in the current syntax tree)
    pub fn itemNode(r: *Resolver, file: FileId, item: u32) Error!?SyntaxNode {
        const tree = try r.itemTree(file);
        return (try r.ctx.get(syntax.FileAstIdMap, file)).get(tree.items[item].ast_id);
    }

    /// Start offset of a member in the file: use this when only the position is needed, since it
    /// does not depend on the parse result (which may have been evicted)
    pub fn itemOffset(r: *Resolver, file: FileId, item: u32) Error!?u32 {
        return (try r.ctx.get(syntax.ItemSummaries, file)).items[item].offset;
    }

    /// Start offset of a container in the file (like `itemOffset`, independent of the parse result)
    pub fn containerOffset(r: *Resolver, ns: Namespace) Error!?u32 {
        const s = try r.ctx.get(syntax.ItemSummaries, ns.file);
        if (ns.container >= s.container_offsets.len) return null;
        return s.container_offsets[ns.container];
    }

    /// Container defined in the body of member `item`, at offset `rel` from the member's start
    pub fn containerAt(r: *Resolver, file: FileId, item: u32, rel: u32) Error!?Namespace {
        const tree = try r.itemTree(file);
        const rels = try r.ctx.get(syntax.ContainerRels, file);
        for (tree.containers, rels, 0..) |c, offset, i| {
            if (c.parent_item != item) continue;
            if (offset == rel) return .{ .file = file, .container = @intCast(i) };
        }
        return null;
    }

    /// Offset of container `ns`, defined in a body, relative to the start of its enclosing member
    pub fn containerRel(r: *Resolver, ns: Namespace) Error!?u32 {
        const rels = try r.ctx.get(syntax.ContainerRels, ns.file);
        return if (ns.container < rels.len) rels[ns.container] else null;
    }

    /// Whether the member may mention name `name` (with false positives): a coarse filter before
    /// building the Body
    pub fn mayMention(r: *Resolver, file: FileId, item: u32, name: []const u8) Error!bool {
        const names = try r.ctx.get(syntax.ItemNames, file);
        return (syntax.ItemSummary{ .offset = null, .names = names[item] }).mayMention(name);
    }

    pub fn containerNode(r: *Resolver, ns: Namespace) Error!?SyntaxNode {
        const tree = try r.itemTree(ns.file);
        return (try r.ctx.get(syntax.FileAstIdMap, ns.file)).get(tree.containers[ns.container].ast_id);
    }

    // ── Name lookup ──────────────────────────────────────────────────

    /// Resolves a name at `scope` of BodyOwner `item`
    pub fn resolveName(r: *Resolver, file: FileId, item: u32, b: *const Body, scope: Body.ScopeId, name: []const u8) Error!?Def {
        if (b.lookup(scope, name)) |binding| return .{ .local = .{ .file = file, .item = item, .binding = binding } };
        return r.resolveContainerName(file, item, name);
    }

    /// Container-level names: member declarations and, when the container is defined in a member's
    /// body, the local names of that member visible at the container's position.
    /// Used at positions without a Body local scope (such as the name in a decltest `test helper`).
    pub fn resolveContainerName(r: *Resolver, file: FileId, item: u32, name: []const u8) Error!?Def {
        return r.resolveInContainer(file, (try r.itemTree(file)).items[item].container, name);
    }

    /// Names visible between the members of container `container_index` (such as at the position of
    /// a member declaration), looked up as in `resolveContainerName`.
    pub fn resolveInContainer(r: *Resolver, file: FileId, container_index: u32, name: []const u8) Error!?Def {
        const tree = try r.itemTree(file);
        var container = container_index;
        while (true) {
            if (lookupDecl(tree, container, name)) |m| return .{ .item = .{ .file = file, .item = m } };
            // The container is defined in a member's body: continue with the local names of that
            // member visible at the container's position
            const parent = tree.containers[container].parent_item orelse return null;
            if (try r.localAtContainer(file, parent, container, name)) |def| return def;
            container = tree.items[parent].container;
        }
    }

    fn localAtContainer(r: *Resolver, file: FileId, parent: u32, container: u32, name: []const u8) Error!?Def {
        const rel = try r.containerRel(.{ .file = file, .container = container }) orelse return null;
        const pb = try r.body(file, parent);
        const binding = pb.lookup(pb.scopeAt(rel), name) orelse return null;
        return .{ .local = .{ .file = file, .item = parent, .binding = binding } };
    }

    /// Members of a container that can be referenced directly by name (declarations; fields are not
    /// names in scope)
    pub fn lookupDecl(tree: *const ItemTree, container: u32, name: []const u8) ?u32 {
        for (tree.containerMembers(container)) |m| {
            const it = tree.items[m];
            switch (it.kind) {
                .@"fn", .@"const", .@"var" => if (it.name) |n| if (std.mem.eql(u8, n, name)) return m,
                else => {},
            }
        }
        return null;
    }

    /// `ns.name`: declarations, and for enums also their fields (`E.a`)
    pub fn memberDef(r: *Resolver, ns: Namespace, name: []const u8) Error!?Def {
        const tree = try r.itemTree(ns.file);
        if (ns.container >= tree.containers.len) return null;
        if (lookupDecl(tree, ns.container, name)) |m| return .{ .item = .{ .file = ns.file, .item = m } };
        if (tree.containers[ns.container].kind == .@"enum") {
            for (tree.containerMembers(ns.container)) |m| {
                const it = tree.items[m];
                if (it.kind == .field and it.name != null and std.mem.eql(u8, it.name.?, name)) return .{ .item = .{ .file = ns.file, .item = m } };
            }
        }
        return null;
    }

    /// The definition an alias like `const f = a.b.c;` ultimately points to; `def` itself when it
    /// is not an alias
    pub fn aliasTarget(r: *Resolver, def: Def) Error!Def {
        var cur = def;
        for (0..max_depth) |_| {
            const it = switch (cur) {
                .item => |it| it,
                else => return cur,
            };
            if ((try r.itemTree(it.file)).items[it.item].kind != .@"const") return cur;
            const b = try r.body(it.file, it.item);
            const value = b.value orelse return cur;
            cur = switch (b.expr(value)) {
                .name_ref => |n| if (b.nameRefIsBuiltin(value)) null else try r.resolveName(it.file, it.item, b, b.expr_scopes[@backingInt(value)], n),
                .field_access => |fa| if (try r.evalNamespace(it.file, it.item, b, fa.lhs)) |ns| try r.memberDef(ns, fa.field orelse return cur) else null,
                else => null,
            } orelse return cur;
        }
        return cur;
    }

    // ── Namespace evaluation ─────────────────────────────────────────

    /// The namespace a definition points to (`const x = @import(...)`, `const S = struct {...}`,
    /// aliases, etc.)
    pub fn namespaceOf(r: *Resolver, def: Def) Error!?Namespace {
        return r.namespaceOfDepth(def, 0);
    }

    fn namespaceOfDepth(r: *Resolver, def: Def, depth: u32) Error!?Namespace {
        if (depth > max_depth) return null;
        switch (def) {
            .file => |f| return if (r.isZon(f)) null else .{ .file = f, .container = 0 },
            .item => |it| {
                const tree = try r.itemTree(it.file);
                switch (tree.items[it.item].kind) {
                    .@"const", .@"var" => {},
                    else => return null,
                }
                const b = try r.body(it.file, it.item);
                const value = b.value orelse return null;
                return r.evalDepth(it.file, it.item, b, value, depth + 1);
            },
            .local => |l| {
                const b = try r.body(l.file, l.item);
                const init = b.binding(l.binding).init orelse return null;
                return r.evalDepth(l.file, l.item, b, init, depth + 1);
            },
        }
    }

    /// The namespace an expression evaluates to
    pub fn evalNamespace(r: *Resolver, file: FileId, item: u32, b: *const Body, e: Body.ExprId) Error!?Namespace {
        return r.evalDepth(file, item, b, e, 0);
    }

    fn evalDepth(r: *Resolver, file: FileId, item: u32, b: *const Body, e: Body.ExprId, depth: u32) Error!?Namespace {
        if (depth > max_depth) return null;
        switch (b.expr(e)) {
            .name_ref => |name| {
                if (b.nameRefIsBuiltin(e)) return null;
                const def = try r.resolveName(file, item, b, b.expr_scopes[@backingInt(e)], name) orelse return null;
                return r.namespaceOfDepth(def, depth + 1);
            },
            .field_access => |fa| {
                const ns = try r.evalDepth(file, item, b, fa.lhs, depth + 1) orelse return null;
                const def = try r.memberDef(ns, fa.field orelse return null) orelse return null;
                return r.namespaceOfDepth(def, depth + 1);
            },
            .builtin_call => |call| {
                if (std.mem.eql(u8, call.name, "@import")) {
                    const target = try r.importTarget(file, b, call.args) orelse return null;
                    return r.namespaceOfDepth(.{ .file = target }, depth + 1);
                }
                if (std.mem.eql(u8, call.name, "@This")) {
                    return .{ .file = file, .container = (try r.itemTree(file)).items[item].container };
                }
                return null;
            },
            .container => return r.containerAt(file, item, b.range(e).start),
            .@"comptime" => |inner| return r.evalDepth(file, item, b, inner, depth + 1),
            else => return null,
        }
    }

    // ── import ───────────────────────────────────────────────────────

    /// Target file of `@import(args)`
    pub fn importTarget(r: *Resolver, file: FileId, b: *const Body, args: []const Body.ExprId) Error!?FileId {
        return r.resolveImport(file, r.importName(b, args) orelse return null);
    }

    /// All targets of `@import(args)` (see `resolveImportTargets`)
    pub fn importTargets(r: *Resolver, file: FileId, b: *const Body, args: []const Body.ExprId) Error![]const FileId {
        return r.resolveImportTargets(file, r.importName(b, args) orelse return &.{});
    }

    /// The argument string of `@import(args)`
    fn importName(r: *Resolver, b: *const Body, args: []const Body.ExprId) ?[]const u8 {
        if (args.len != 1) return null;
        const raw = switch (b.expr(args[0])) {
            .literal => |text| text,
            else => return null,
        };
        return stringValue(r.arena, raw);
    }

    pub fn resolveImport(r: *Resolver, file: FileId, name: []const u8) Error!?FileId {
        if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) {
            const dir = std.fs.path.dirname(r.vfs().path(file)) orelse return null;
            return try r.vfs().intern(try std.fs.path.join(r.arena, &.{ dir, name }));
        }
        // Through the file's import table: depends only on the part relevant to this file
        // (see `FileImports`)
        if ((try r.ctx.get(ModuleGraph.FileImports, file)).get(name)) |target| return target;
        const graph = try r.ctx.get(ModuleGraph.Input, {}) orelse return null;
        return graph.importTarget(file, name);
    }

    /// The file at relative path `path` in the directory of `file` (`@embedFile`); null for
    /// absolute paths (the compiler rejects them)
    pub fn relativeFile(r: *Resolver, file: FileId, path: []const u8) Error!?FileId {
        if (std.fs.path.isAbsolute(path)) return null;
        const dir = std.fs.path.dirname(r.vfs().path(file)) orelse return null;
        return try r.vfs().intern(try std.fs.path.join(r.arena, &.{ dir, path }));
    }

    /// All targets of `@import(name)` in a file: there are several when the modules the file
    /// belongs to import different modules as `name`, ordered by module priority, the first one
    /// being the result of `resolveImport`; a relative path has at most one. Reads the module graph
    /// directly, without `FileImports` cutting off other changes; meant for requests such as goto,
    /// and must not be used in inference.
    pub fn resolveImportTargets(r: *Resolver, file: FileId, name: []const u8) Error![]const FileId {
        if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) {
            const target = try r.resolveImport(file, name) orelse return &.{};
            return r.arena.dupe(FileId, &.{target});
        }
        const graph = try r.ctx.get(ModuleGraph.Input, {}) orelse return &.{};
        return graph.importTargets(r.arena, file, name);
    }

    // ── Positions ────────────────────────────────────────────────────

    /// The innermost member containing `offset` (`inclusive_end`: a cursor at the end of the member
    /// also counts)
    pub fn ownerAt(r: *Resolver, file: FileId, offset: u32, inclusive_end: bool) Error!?u32 {
        const tree = try r.itemTree(file);
        const map = try r.ctx.get(syntax.FileAstIdMap, file);
        var best: ?u32 = null;
        var best_len: u32 = std.math.maxInt(u32);
        for (tree.items, 0..) |it, i| {
            const node = map.get(it.ast_id) orelse continue;
            const range = node.range();
            const inside = range.start <= offset and (offset < range.end or (inclusive_end and offset == range.end));
            if (inside and range.end - range.start < best_len) {
                best = @intCast(i);
                best_len = range.end - range.start;
            }
        }
        return best;
    }

    /// Whether the member's container allows fields written as just a name (enums, unions; this
    /// determines where a field's name is)
    pub fn inEnum(r: *Resolver, file: FileId, item: u32) Error!bool {
        const tree = try r.itemTree(file);
        return ItemTree.bareFieldNames(tree.containers[tree.items[item].container].kind);
    }

    /// The file and name position of a definition (the start of the file for a file)
    pub fn location(r: *Resolver, def: Def) Error!?struct { file: FileId, start: u32, end: u32 } {
        switch (def) {
            .file => |f| return .{ .file = f, .start = 0, .end = 0 },
            .item => |it| {
                const node = try r.itemNode(it.file, it.item) orelse return null;
                if (ast.memberName(node, try r.inEnum(it.file, it.item))) |t| return .{ .file = it.file, .start = t.offset, .end = t.offset + @as(u32, @intCast(t.text.len)) };
                return .{ .file = it.file, .start = node.offset, .end = node.offset };
            },
            .local => |l| {
                const node = try r.itemNode(l.file, l.item) orelse return null;
                const range = (try r.body(l.file, l.item)).binding(l.binding).range;
                return .{ .file = l.file, .start = node.offset + range.start, .end = node.offset + range.end };
            },
        }
    }
};

/// Value of a string literal; null when it is not a valid single-line string
fn stringValue(arena: Allocator, raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"') return null;
    return std.zig.string_literal.parseAlloc(arena, raw) catch null;
}

test {
    _ = @import("resolve_test.zig");
}
