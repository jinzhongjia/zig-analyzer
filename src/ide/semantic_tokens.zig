//! Semantic highlighting: reuses name resolution and type inference per member; syntactic
//! classification keeps incomplete code readable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const tree = @import("../syntax/tree.zig");
const ast = @import("../syntax/ast.zig");
const SyntaxNode = tree.SyntaxNode;
const kind_mod = @import("../syntax/kind.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const database = @import("../database.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const ItemTree = @import("../syntax/ItemTree.zig");
const Body = @import("../hir/Body.zig");
const InternPool = @import("../sema/InternPool.zig");
const infer = @import("../sema/infer.zig");
const queries = @import("../sema/queries.zig");
const context = @import("context.zig");
const seed = @import("../ide_db/seed.zig");
const symbol_kind = @import("../ide_db/symbol_kind.zig");
const OwnerKey = database.hir.OwnerKey;

pub const TokenType = enum(u32) {
    type,
    parameter,
    variable,
    property,
    enumMember,
    function,
    keyword,
    comment,
    string,
    number,
    label,
    namespace,
    @"struct",
    @"enum",
    method,
    operator,
    typeParameter,
};

pub const Modifier = struct {
    pub const declaration: u32 = 1 << 0;
    pub const readonly: u32 = 1 << 1;
    pub const documentation: u32 = 1 << 2;
    pub const defaultLibrary: u32 = 1 << 3;
    pub const unused: u32 = 1 << 4;
    pub const global: u32 = 1 << 5;
};

pub const legend: types.SemanticTokensLegend = .{
    .tokenTypes = blk: {
        const names = @typeInfo(TokenType).@"enum".field_names;
        var out: [names.len][]const u8 = undefined;
        for (names, 0..) |n, i| out[i] = n;
        const final = out;
        break :blk &final;
    },
    .tokenModifiers = &.{ "declaration", "readonly", "documentation", "defaultLibrary", "unused", "global" },
};

pub const Options = struct {
    /// Do not emit `syntactic` tokens, leaving them to the editor's syntax highlighting; emitted
    /// tokens are identical to the same tokens in the full result
    partial: bool = false,
    /// Declarations of and references to container-level `var`s carry `global`
    global_var: bool = false,
};

pub fn semanticTokens(r: *Resolver, file: FileId, lines: offsets.LineIndex, enc: offsets.Encoding, range: ?types.Range, options: Options) resolve.Error![]const u32 {
    if (range) |requested| if (!before(requested.start, requested.end)) return &.{};
    var b: Builder = .{ .r = r, .lines = lines, .enc = enc, .range = range, .options = options };
    if (range) |requested| {
        const start = offsets.positionToOffset(lines.text, requested.start, enc);
        var end = offsets.positionToOffset(lines.text, requested.end, enc);
        // When the end position falls in the middle of a multi-code-unit character, keep the
        // whole token that contains it.
        if (end < lines.text.len and before(lines.position(end, enc), requested.end)) {
            const width = std.unicode.utf8ByteSequenceLength(lines.text[end]) catch 1;
            end = @min(end + width, lines.text.len);
        }
        if (start >= end) return &.{};
        b.visible = .{ .start = @intCast(start), .end = @intCast(end) };
    }
    const parse = try r.ctx.get(database.syntax.ParseFile, file);
    b.zon = parse.mode == .zon;
    const root = parse.rootNode();
    try b.collect(file, root);
    try b.visit(root, false);
    return b.data.items;
}

const Class = struct { type: TokenType, mods: u32 = 0 };
const BindingKey = struct { owner: OwnerKey, binding: Body.BindingId };
const BindingDecl = struct { key: BindingKey, end: u32, class: Class, can_be_unused: bool };

fn tokenType(kind: symbol_kind.Kind) TokenType {
    return switch (kind) {
        .namespace => .namespace,
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .type => .type,
        .function => .function,
        .method => .method,
        .variable => .variable,
        .field => .property,
        .enum_member => .enumMember,
        .parameter => .parameter,
        .type_parameter => .typeParameter,
    };
}

/// Members whose declarations are classified as variable or type are refined at references by the
/// concrete type there (`itemClassAt`); other classes are independent of the type
fn dependsOnType(c: Class) bool {
    return c.type == .variable or c.type == .type;
}

/// Classes that can be determined without name resolution or type inference: keywords, comments,
/// literals, operators, labels, and builtin names (`@import`, `u32`, `true`)
fn syntactic(c: Class) bool {
    return switch (c.type) {
        .keyword, .comment, .string, .number, .operator, .label => true,
        else => c.mods & Modifier.defaultLibrary != 0,
    };
}

const Builder = struct {
    r: *Resolver,
    lines: offsets.LineIndex,
    enc: offsets.Encoding,
    range: ?types.Range,
    options: Options,
    /// The file is parsed as ZON
    zon: bool = false,
    visible: ?tree.TextRange = null,
    /// Keyed by the end of the name token, so a field access does not need to walk its left-hand
    /// expression again.
    names: std.AutoHashMapUnmanaged(u32, Class) = .empty,
    visible_names: std.AutoHashMapUnmanaged(u32, void) = .empty,
    classes: std.AutoHashMapUnmanaged(OwnerKey, Class) = .empty,
    items: std.AutoHashMapUnmanaged(OwnerKey, u32) = .empty,
    indexed: std.AutoHashMapUnmanaged(FileId, void) = .empty,
    used: std.AutoHashMapUnmanaged(BindingKey, void) = .empty,
    declarations: std.ArrayList(BindingDecl) = .empty,
    data: std.ArrayList(u32) = .empty,
    prev: types.Position = .{ .line = 0, .character = 0 },
    cursor_offset: usize = 0,
    cursor: types.Position = .{ .line = 0, .character = 0 },

    fn intersects(b: *const Builder, span: tree.TextRange) bool {
        const visible = b.visible orelse return true;
        return span.start < visible.end and visible.start < span.end;
    }

    fn selectOwners(b: *Builder, node: SyntaxNode, current: ?u32, owners: *const std.AutoHashMapUnmanaged(u32, u32), selected: []bool) Allocator.Error!void {
        if (!b.intersects(node.range())) return;
        const owner = owners.get(node.offset) orelse current;
        var children = node.children();
        while (children.next()) |child| switch (child) {
            .node => |n| try b.selectOwners(n, owner, owners, selected),
            .token => |t| if (t.kind == .identifier and b.intersects(t.range())) {
                if (owner) |index| selected[index] = true;
                try b.visible_names.put(b.r.arena, t.range().end, {});
            },
        };
    }

    fn markUse(b: *Builder, def: resolve.Def) resolve.Error!void {
        if (def == .local) {
            const local = def.local;
            // The current file already has its owner index built, and bindings returned by
            // name resolution belong to the lexical chain of that file.
            const key: OwnerKey = .{ .file = local.file, .item = (try b.r.itemTree(local.file)).items[local.item].ast_id };
            try b.used.put(b.r.arena, .{ .owner = key, .binding = local.binding }, {});
        }
    }

    fn nestedUses(b: *Builder, file: FileId, index: u32, first_child: []const ?u32, next_sibling: []const ?u32, names: *const std.StringHashMapUnmanaged(void)) resolve.Error!void {
        var child = first_child[index];
        while (child) |i| : (child = next_sibling[i]) {
            var may_mention = false;
            var wanted = names.keyIterator();
            while (wanted.next()) |name| {
                if (try b.r.mayMention(file, i, name.*)) {
                    may_mention = true;
                    break;
                }
            }
            if (may_mention) {
                const body = try b.r.body(file, i);
                for (body.exprs, 0..) |expr, e| {
                    const name = switch (expr) {
                        .name_ref => |n| n,
                        else => continue,
                    };
                    if (!names.contains(name)) continue;
                    const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(e)));
                    if (!body.nameRefIsEscaped(id) and (isPrimitiveType(name) or isPrimitiveValue(name) or std.mem.eql(u8, name, "_"))) continue;
                    if (try b.r.resolveName(file, i, body, body.expr_scopes[e], name)) |def| try b.markUse(def);
                }
            }
            try b.nestedUses(file, i, first_child, next_sibling, names);
        }
    }

    fn indexFile(b: *Builder, file: FileId) resolve.Error!void {
        if (b.indexed.contains(file)) return;
        const items = (try b.r.itemTree(file)).items;
        for (items, 0..) |item, i| try b.items.put(b.r.arena, .{ .file = file, .item = item.ast_id }, @intCast(i));
        try b.indexed.put(b.r.arena, file, {});
    }

    fn itemClass(b: *Builder, key: OwnerKey) resolve.Error!Class {
        if (b.classes.get(key)) |c| return c;
        try b.indexFile(key.file);
        const index = b.items.get(key) orelse return .{ .type = .variable };
        const symbol = try symbol_kind.ofDecl(b.r, key.file, index);
        // ItemTree members are all container-level
        const global = b.options.global_var and (try b.r.itemTree(key.file)).items[index].kind == .@"var";
        const c: Class = .{ .type = tokenType(symbol.kind), .mods = (if (symbol.readonly) Modifier.readonly else 0) | (if (global) Modifier.global else 0) };
        try b.classes.put(b.r.arena, key, c);
        return c;
    }

    fn itemClassAt(b: *Builder, key: OwnerKey, tv: InternPool.TypedValue) resolve.Error!Class {
        const c = try b.itemClass(key);
        // The cache stores only the abstract declaration class; the concrete type at the
        // current position must not be written back, as it would pollute other instances.
        if (dependsOnType(c) and !seed.wanted(b.r.ctx.db.env.ip, tv)) {
            return b.valueClass(tv, c.type, c.mods);
        }
        return c;
    }

    /// Whether the class at a name reference depends on the type there (see `defClass`): if not,
    /// there is no need to infer with a call-site instance
    fn nameDependsOnType(b: *Builder, def: ?resolve.Def, abstract: InternPool.TypedValue, owner: OwnerKey, body: *const Body) resolve.Error!bool {
        return switch (def orelse return false) {
            .file => false,
            .item => |it| dependsOnType(try b.itemClass(try b.r.ownerKey(it.file, it.item))),
            // A type parameter is a type in every instance (see `bindingClass`)
            .local => |local| !abstract.isType() or blk: {
                const key = try b.r.ownerKey(local.file, local.item);
                const lb = if (std.meta.eql(key, owner)) body else try b.r.body(local.file, local.item);
                break :blk lb.binding(local.binding).kind != .param;
            },
        };
    }

    /// Whether the class at a member access or enum literal depends on the type there: when
    /// abstract inference cannot find the member, an instance may supply it
    fn memberDependsOnType(b: *Builder, member: ?OwnerKey, abstract: InternPool.TypedValue) resolve.Error!bool {
        const key = member orelse return true;
        return seed.wanted(b.r.ctx.db.env.ip, abstract) and dependsOnType(try b.itemClass(key));
    }

    /// A value that is neither a type nor a function gets `fallback` (see `symbol_kind.ofValue`)
    fn valueClass(b: *Builder, tv: InternPool.TypedValue, fallback: TokenType, mods: u32) Class {
        const kind = symbol_kind.ofValue(b.r.ctx.db.env.ip, tv, .variable);
        return .{ .type = if (kind == .variable) fallback else tokenType(kind), .mods = mods };
    }

    fn bindingClass(b: *Builder, binding: Body.Binding, tv: InternPool.TypedValue) Class {
        const symbol = symbol_kind.ofBinding(b.r.ctx.db.env.ip, binding, tv);
        return .{ .type = tokenType(symbol.kind), .mods = if (symbol.readonly) Modifier.readonly else 0 };
    }

    fn defClass(b: *Builder, def: resolve.Def, tv: InternPool.TypedValue, owner: OwnerKey, body: *const Body, res: *const infer.Result) resolve.Error!Class {
        return switch (def) {
            .file => .{ .type = .namespace },
            .item => |it| blk: {
                const key = try b.r.ownerKey(it.file, it.item);
                break :blk try b.itemClassAt(key, tv);
            },
            .local => |local| blk: {
                const key = try b.r.ownerKey(local.file, local.item);
                try b.used.put(b.r.arena, .{ .owner = key, .binding = local.binding }, {});
                const lb = if (std.meta.eql(key, owner)) body else try b.r.body(local.file, local.item);
                const binding = lb.binding(local.binding);
                const i = @backingInt(local.binding);
                const value = if (tv.ty == .unknown) local_value: {
                    const local_res = if (std.meta.eql(key, owner)) res else try b.r.ctx.get(database.sema.Infer, .{ .owner = key, .mode = .full });
                    break :local_value if (i < local_res.bindings.len) local_res.bindings[i] else tv;
                } else tv;
                break :blk b.bindingClass(binding, value);
            },
        };
    }

    fn collect(b: *Builder, file: FileId, root: SyntaxNode) resolve.Error!void {
        try b.indexFile(file);
        const itree = try b.r.itemTree(file);
        const ast_ids = try b.r.ctx.get(database.syntax.FileAstIdMap, file);
        const indexed_len = if (b.visible != null) itree.items.len else 0;
        const selected = try b.r.arena.alloc(bool, indexed_len);
        @memset(selected, false);
        const first_child = try b.r.arena.alloc(?u32, indexed_len);
        const next_sibling = try b.r.arena.alloc(?u32, indexed_len);
        const usage_names = try b.r.arena.alloc(std.StringHashMapUnmanaged(void), indexed_len);
        @memset(first_child, null);
        @memset(next_sibling, null);
        @memset(usage_names, .empty);
        if (b.visible != null) {
            var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
            for (itree.items, 0..) |item, index| {
                if (ast_ids.get(item.ast_id)) |node| try owners.put(b.r.arena, node.offset, @intCast(index));
                if (itree.containers[item.container].parent_item) |parent| {
                    next_sibling[index] = first_child[parent];
                    first_child[parent] = @intCast(index);
                }
            }
            try b.selectOwners(root, null, &owners, selected);
        }
        for (itree.items, 0..) |item, index| {
            if (b.visible != null and !selected[index]) continue;
            const key: OwnerKey = .{ .file = file, .item = item.ast_id };
            const node = ast_ids.get(item.ast_id) orelse continue;
            // Get the Body and the full inference result only once per owner; name lookup
            // uses the scopes saved during lowering.
            const body = try b.r.ctx.get(database.hir.ItemBody, key);
            const res = try b.r.ctx.get(database.sema.Infer, .{ .owner = key, .mode = .full });
            var refiner = try seed.Refiner.init(b.r, file, @intCast(index), node.offset, body, res);
            var a: context.At = .{
                .file = file,
                .item = @intCast(index),
                .node = node,
                .owner = key,
                .body = body,
                .res = res,
                .rel = 0,
                .ip = b.r.ctx.db.env.ip,
            };
            for (body.bindings, 0..) |binding, i| {
                if (binding.range.end <= binding.range.start) continue;
                if (binding.range.end - binding.range.start == 1 and std.mem.eql(u8, binding.name, "_")) continue;
                if (b.visible != null and !b.visible_names.contains(node.offset + binding.range.end)) continue;
                const id: Body.BindingId = @fromBackingInt(@as(u32, @intCast(i)));
                a.seeded = null;
                // A type parameter is a type in every instance, so its class does not change
                const abstract_binding = a.bindingType(id);
                if (seed.wanted(a.ip, abstract_binding) and !(binding.kind == .param and abstract_binding.isType())) {
                    a.seeded = try refiner.at(binding.range.end - 1, .{ .binding = id });
                }
                var c = b.bindingClass(binding, a.bindingType(id));
                c.mods |= Modifier.declaration;
                try b.declarations.append(b.r.arena, .{
                    .key = .{ .owner = key, .binding = @fromBackingInt(@as(u32, @intCast(i))) },
                    .end = node.offset + binding.range.end,
                    .class = c,
                    .can_be_unused = binding.kind != .param or if (ast.cast(ast.FnDecl, node)) |f| f.body() != null else false,
                });
                if (b.visible != null) try usage_names[index].put(b.r.arena, binding.name, {});
            }
            var initializer_value: InternPool.TypedValue = .unknown;
            for (body.exprs, 0..) |expr, i| {
                const span = body.expr_ranges[i];
                if (span.end <= span.start) continue;
                const expr_id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
                const builtin = expr == .name_ref and !body.nameRefIsEscaped(expr_id) and (isPrimitiveType(expr.name_ref) or isPrimitiveValue(expr.name_ref) or std.mem.eql(u8, expr.name_ref, "_"));
                var lexical_def: ?resolve.Def = null;
                // Lexical references outside the viewport still affect the unused modifier in the
                // current owner; their types do not need to be inferred.
                if (expr == .name_ref and !builtin) {
                    lexical_def = try b.r.resolveName(file, @intCast(index), body, body.expr_scopes[i], expr.name_ref);
                    if (lexical_def) |def| try b.markUse(def);
                }
                if (b.visible != null and !b.visible_names.contains(node.offset + span.end)) continue;
                a.seeded = null;
                const abstract = a.exprType(expr_id);
                // Infer with a call-site instance only where the class may depend on the
                // concrete type: references to functions, namespaces, and so on have the same
                // class in every instance
                switch (expr) {
                    .name_ref => if (!builtin and seed.wanted(a.ip, abstract) and try b.nameDependsOnType(lexical_def, abstract, key, body)) {
                        a.seeded = try refiner.at(span.end - 1, .{ .expr = expr_id });
                    },
                    .field_access => |fa| if (fa.field != null and try b.memberDependsOnType(a.member(expr_id), abstract)) {
                        a.seeded = try refiner.at(span.end - 1, .{ .expr = expr_id });
                    },
                    .enum_literal => if (try b.memberDependsOnType(a.member(expr_id), abstract)) {
                        a.seeded = try refiner.at(span.end - 1, .{ .expr = expr_id });
                    },
                    else => {},
                }
                const tv = a.exprType(expr_id);
                if (body.value == expr_id) initializer_value = tv;
                const c: Class = switch (expr) {
                    .name_ref => |name| blk: {
                        if (span.end - span.start == 1 and std.mem.eql(u8, name, "_")) continue;
                        const escaped = body.nameRefIsEscaped(expr_id);
                        if (!escaped) {
                            if (isPrimitiveType(name)) break :blk .{ .type = .type, .mods = Modifier.defaultLibrary };
                            if (isPrimitiveValue(name)) break :blk .{ .type = .keyword, .mods = Modifier.defaultLibrary };
                        }
                        if (lexical_def) |def| break :blk try b.defClass(def, tv, key, body, res);
                        break :blk .{ .type = .variable };
                    },
                    .field_access => |fa| blk: {
                        if (fa.field == null) continue;
                        if (a.member(expr_id)) |member| break :blk try b.itemClassAt(member, tv);
                        const lhs = a.exprType(fa.lhs);
                        // Constructed enums and error sets have no ItemTree members but can
                        // still be classified by the type of the left-hand side.
                        if (lhs.asType()) |ty| switch (b.r.ctx.db.env.ip.key(ty)) {
                            // A namespace member of actual function type may lack a member
                            // record; callable fields on values remain property.
                            .container_type => if (b.r.ctx.db.env.ip.key(tv.ty) == .fn_type) {
                                break :blk .{ .type = .function };
                            },
                            .error_set_type, .inferred_error_set => {
                                if (try queries.errorSetMembers(b.r, ty)) |names| {
                                    for (names) |name| if (std.mem.eql(u8, name, fa.field.?)) break :blk .{ .type = .enumMember };
                                }
                            },
                            .union_tag_type, .reified_type => {
                                if (tv.val) |value| if (b.r.ctx.db.env.ip.key(value) == .enum_tag) break :blk .{ .type = .enumMember };
                            },
                            .simple_type => |simple| if (simple == .anyerror) break :blk .{ .type = .enumMember },
                            else => {},
                        };
                        break :blk .{ .type = .property };
                    },
                    .enum_literal => blk: {
                        if (a.member(expr_id)) |member| {
                            const c = try b.itemClassAt(member, tv);
                            break :blk if (c.type == .property) .{ .type = .enumMember } else c;
                        }
                        break :blk .{ .type = .enumMember };
                    },
                    .error_value => .{ .type = .enumMember },
                    else => continue,
                };
                try b.names.put(b.r.arena, node.offset + span.end, c);
            }
            // A bare enum member may also be a name_ref in the error-tolerant HIR;
            // the declaration overrides that syntactic expression.
            if (ast.memberName(node, ItemTree.bareFieldNames(itree.containers[item.container].kind))) |name| if (b.visible == null or b.visible_names.contains(name.range().end)) {
                var tv = initializer_value;
                if ((item.kind == .@"const" or item.kind == .@"var") and seed.wanted(a.ip, tv) and dependsOnType(try b.itemClass(key))) if (body.value) |initializer| {
                    a.seeded = null;
                    const span = body.range(initializer);
                    if (span.end > span.start and seed.wanted(a.ip, a.exprType(initializer))) {
                        a.seeded = try refiner.at(span.end - 1, .{ .expr = initializer });
                    }
                    tv = a.exprType(initializer);
                };
                var c = try b.itemClassAt(key, tv);
                c.mods |= Modifier.declaration;
                try b.names.put(b.r.arena, name.offset + @as(u32, @intCast(name.text.len)), c);
            };
        }
        if (b.visible != null) for (usage_names, 0..) |*names, index| {
            if (names.count() != 0) try b.nestedUses(file, @intCast(index), first_child, next_sibling, names);
        };
        // Members of nested containers may reference outer local bindings; whether a
        // declaration is unused is decided only after all owners are collected.
        for (b.declarations.items) |declaration| {
            var c = declaration.class;
            if (declaration.can_be_unused and !b.used.contains(declaration.key)) c.mods |= Modifier.unused;
            try b.names.put(b.r.arena, declaration.end, c);
        }
    }

    fn visit(b: *Builder, node: SyntaxNode, in_enum: bool) Allocator.Error!void {
        if (!b.intersects(node.range())) return;
        const child_in_enum = if (node.kind() == .container_decl) node.childToken(.keyword_enum) != null and node.childToken(.keyword_union) == null else in_enum;
        var it = node.children();
        while (it.next()) |element| switch (element) {
            .node => |child| try b.visit(child, child_in_enum),
            .token => |token| {
                if (!b.intersects(token.range())) continue;
                const semantic = if (token.kind == .identifier) b.names.get(token.offset + @as(u32, @intCast(token.text.len))) else null;
                const c = semantic orelse syntaxClass(token, node, child_in_enum, b.zon) orelse continue;
                if (!(b.options.partial and syntactic(c))) try b.emit(token, c);
            },
        };
    }

    fn emit(b: *Builder, token: tree.SyntaxToken, c: Class) Allocator.Error!void {
        const start = b.position(token.offset);
        const end = b.position(token.offset + token.text.len);
        if (end.line != start.line or end.character == start.character) return;
        if (b.range) |range| {
            if (!before(range.start, range.end) or !before(start, range.end) or !before(range.start, end)) return;
        }
        const delta_line = start.line - b.prev.line;
        const delta_char = if (delta_line == 0) start.character - b.prev.character else start.character;
        try b.data.appendSlice(b.r.arena, &.{ delta_line, delta_char, end.character - start.character, @backingInt(c.type), c.mods });
        b.prev = start;
    }

    fn position(b: *Builder, offset: usize) types.Position {
        b.cursor = b.lines.positionAfter(b.cursor_offset, b.cursor, offset, b.enc);
        b.cursor_offset = offset;
        return b.cursor;
    }
};

fn before(a: types.Position, b: types.Position) bool {
    return a.line < b.line or (a.line == b.line and a.character < b.character);
}

/// `zon`: the file is parsed as ZON, where `inf` and `nan` are float literals
fn syntaxClass(token: tree.SyntaxToken, parent: SyntaxNode, in_enum: bool, zon: bool) ?Class {
    const decl = Modifier.declaration;
    switch (token.kind) {
        .line_comment => return .{ .type = .comment },
        .doc_comment, .container_doc_comment => return .{ .type = .comment, .mods = Modifier.documentation },
        .string_literal, .char_literal, .multiline_string_literal_line => return .{ .type = .string },
        .number_literal => return .{ .type = .number },
        .builtin => return .{ .type = .function, .mods = Modifier.defaultLibrary },
        .identifier => {
            if (std.mem.eql(u8, token.text, "_")) return null;
            return switch (parent.kind()) {
                .fn_proto => if (parent.childToken(.identifier).?.offset == token.offset) .{ .type = .function, .mods = decl } else null,
                .var_decl => if (parent.childToken(.identifier).?.offset == token.offset) .{ .type = .variable, .mods = decl | (if (parent.childToken(.keyword_const) != null) Modifier.readonly else 0) } else .{ .type = .variable },
                .container_field => .{ .type = if (in_enum) .enumMember else .property, .mods = decl },
                .param => .{ .type = .parameter, .mods = decl | Modifier.readonly },
                .payload => .{ .type = .variable, .mods = decl | Modifier.readonly },
                .field_access, .field_init => .{ .type = .property },
                .enum_literal, .error_value => .{ .type = .enumMember },
                .error_set_decl => .{ .type = .enumMember, .mods = decl },
                .label => .{ .type = .label, .mods = decl },
                .break_label => .{ .type = .label },
                .name_ref => if (zon and Body.zonFloatValue(token.text) != null) .{ .type = .number } else if (isPrimitiveType(token.text)) .{ .type = .type, .mods = Modifier.defaultLibrary } else if (isPrimitiveValue(token.text)) .{ .type = .keyword, .mods = Modifier.defaultLibrary } else .{ .type = .variable },
                else => null,
            };
        },
        else => {
            const tag = kind_mod.toTokenTag(token.kind) orelse return null;
            if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) return .{ .type = .keyword };
            const operators = std.StaticStringMap(void).initComptime(.{
                .{"="},   .{"+"},   .{"-"},   .{"*"},    .{"/"},  .{"%"},  .{"!"},   .{"~"},   .{"&"},   .{"|"},   .{"^"},
                .{"=="},  .{"!="},  .{"<"},   .{">"},    .{"<="}, .{">="}, .{"<<"},  .{">>"},  .{"+%"},  .{"-%"},  .{"*%"},
                .{"+|"},  .{"-|"},  .{"*|"},  .{"<<|"},  .{"++"}, .{"**"}, .{"?"},   .{".*"},  .{".?"},  .{"+="},  .{"-="},
                .{"*="},  .{"/="},  .{"%="},  .{"&="},   .{"|="}, .{"^="}, .{"<<="}, .{">>="}, .{"+%="}, .{"-%="}, .{"*%="},
                .{"+|="}, .{"-|="}, .{"*|="}, .{"<<|="},
            });
            return if (operators.has(token.text)) .{ .type = .operator } else null;
        },
    }
}

fn isPrimitiveValue(name: []const u8) bool {
    const values = std.StaticStringMap(void).initComptime(.{ .{"true"}, .{"false"}, .{"null"}, .{"undefined"} });
    return values.has(name);
}

fn isPrimitiveType(name: []const u8) bool {
    return std.zig.primitives.isPrimitive(name) and !isPrimitiveValue(name);
}

test {
    _ = @import("semantic_tokens_test.zig");
}
