//! Completion: after `a.`, lists the members of the namespace; after `.`, lists members by the
//! expected type, and in initializers the fields not yet assigned; after `error.`, lists error
//! names; after `@`, lists builtins; inside `@import("`, lists modules and files; after `break :` /
//! `continue :`, lists labels; otherwise lists the names visible at the cursor (local names and
//! the declarations of enclosing containers). When `build.zig.zon` has no result type, its fields
//! and paths are listed by the built-in schema (see `manifest.zig`).
//! No completion in comments and strings (other than `@import("` and the paths of `build.zig.zon`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const ItemTree = @import("../syntax/ItemTree.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const context = @import("context.zig");
const infer = @import("../sema/infer.zig");
const symbol_kind = @import("../ide_db/symbol_kind.zig");
const queries = @import("../sema/queries.zig");
const render = @import("../sema/render.zig");
const eval = @import("../sema/eval.zig");
const InternPool = @import("../sema/InternPool.zig");
const TypedValue = InternPool.TypedValue;
const Index = InternPool.Index;
const database = @import("../database.zig");
const ModuleGraph = @import("../names/ModuleGraph.zig");
const builtins = @import("builtins.zig");
const manifest = @import("manifest.zig");
const imports = @import("../ide_db/imports.zig");
const SyntaxNode = @import("../syntax/tree.zig").SyntaxNode;
const ast = @import("../syntax/ast.zig");
const isTrivia = @import("../syntax/kind.zig").isTrivia;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;
const fuzzy = @import("../ide_db/fuzzy.zig");
const value = @import("../sema/value.zig");

pub const Options = struct {
    auto_import: bool = true,
    /// Even when auto-import is not offered, determine whether the cursor is at a name that can be
    /// auto-imported (`Result.import_position`)
    detect_import_position: bool = false,
    /// Maximum number of candidates besides the names in scope (member paths of local values and
    /// auto-import candidates) offered in total (the highest-scoring ones are kept);
    /// `maxInt(usize)` for no limit
    max_auto_imports: usize = 128,
    /// A new import added by auto-import is placed where it belongs in an organized import block
    /// (configuration `imports.*`)
    imports: @import("../ide_db/organize_imports.zig").Options = .{},
};

pub const Result = struct {
    items: []const Item,
    is_incomplete: bool = false,
    /// The cursor is at a name that can be auto-imported (when auto-import is offered, or when the
    /// check is requested)
    import_position: bool = false,
};

pub const Item = struct {
    label: []const u8,
    kind: Kind,
    /// Doc comment
    doc: ?[]const u8 = null,
    /// Type
    detail: ?[]const u8 = null,
    /// Range to replace (byte offsets in the file; the inserted text is `label`); when null, the
    /// client determines it by word. Needed for characters that are not part of a word, such as `@`
    /// and the `/` in paths.
    replace: ?Range = null,
    filter: ?[]const u8 = null,
    qualifier: ?[]const u8 = null,
    /// The rank in name completion (see `rank`)
    sort: ?[]const u8 = null,
    /// Source weight of a name in scope (see `rank`); 0 when it is not a name in scope
    weight: f32 = 0,
    score: f32 = 0,
    import_edit: ?imports.Edit = null,
    /// The definition referred to, from which the signature and documentation are given when the
    /// item is selected (see `describe`): for auto-import candidates and functions
    target: ?imports.Target = null,
    /// The value the candidate refers to in name completion, whose type is computed when ranking
    /// by the expected type (see `Expected`)
    origin: Origin = .none,

    pub const Origin = union(enum) {
        none,
        /// The type is known: local names and member paths of local values
        value: TypedValue,
        /// A declaration or a file (declarations in scope, auto-import candidates): the type is
        /// computed only when needed
        target: imports.Target,
    };

    pub const Kind = enum { param, type_param, constant, variable, function, method, namespace, @"struct", @"enum", type, field, enum_member, error_name, builtin, module, file, folder, label };
    pub const Range = struct { start: u32, end: u32 };
};

pub fn complete(r: *Resolver, file: FileId, offset: u32, options: Options) resolve.Error!Result {
    var owner: imports.Owner = .unknown;
    var names: NameContext = .{};
    const base = try completeVisible(r, file, offset, &owner, &names);
    // Auto-import only in Zig source files: inserting an import declaration into a `.zon` or
    // similar file would break it
    if (!imports.isZigSource(r.ctx.db.env.vfs.path(file))) return .{ .items = base };
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    if (offset == 0 or offset > text.len) return .{ .items = base };
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const name = try importPrefix(r.arena, root, text, offset) orelse return .{ .items = base };
    var items: std.ArrayList(Item) = .empty;
    try items.appendSlice(r.arena, base);
    var result: Result = .{ .items = &.{}, .import_position = options.auto_import or options.detect_import_position };
    const limit = options.max_auto_imports;
    const paths = try localMembers(r, file, names.roots.items, name, limit);
    var extra: std.ArrayList(Item) = .empty;
    try extra.appendSlice(r.arena, paths.items);
    result.is_incomplete = paths.incomplete;
    if (options.auto_import) {
        const found = try imports.complete(r, file, offset, owner, name.prefix, limit, options.imports);
        result.is_incomplete = result.is_incomplete or found.is_incomplete;
        for (found.items) |candidate| {
            // The core (`imports.complete`) has already rendered the path segment by segment;
            // the whole qualified expression must not be escaped as an identifier again.
            const filter = try completionFilter(r.arena, name, candidate.filter);
            var duplicate = false;
            for (items.items[0..base.len]) |*visible| if (std.mem.eql(u8, visible.label, candidate.label)) {
                // Only visible bindings are merged; auto-import items with the same name from
                // different sources must remain separate choices.
                if (candidate.import_edit == null) {
                    visible.replace = name.range;
                    visible.filter = filter;
                    visible.qualifier = candidate.qualifier;
                    visible.target = candidate.target;
                }
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            try extra.append(r.arena, .{
                .label = candidate.label,
                .kind = switch (candidate.kind) {
                    .function => .function,
                    .constant => .constant,
                    .variable => .variable,
                    .namespace => .namespace,
                    .@"struct" => .@"struct",
                    .@"enum" => .@"enum",
                    .type => .type,
                    .module => .module,
                    .file => .file,
                },
                .doc = candidate.doc,
                .replace = name.range,
                .filter = filter,
                .qualifier = candidate.qualifier,
                .score = candidate.score,
                .import_edit = candidate.import_edit,
                .target = candidate.target,
                .origin = .{ .target = candidate.target },
            });
        }
    }
    if (extra.items.len > limit) {
        std.mem.sort(Item, extra.items, {}, higherScore);
        extra.shrinkRetainingCapacity(limit);
        result.is_incomplete = true;
    }
    try items.appendSlice(r.arena, extra.items);
    try rank(r.arena, items.items, name.prefix, try expectedAt(r, file, offset, names.at));
    result.items = items.items;
    return result;
}

/// Order of name completion (`Item.sort`): the score of a name in scope is its match score (see
/// `fuzzy`) multiplied by its source weight (`Item.weight`), and member paths of local values and
/// auto-import candidates take their own scores (see `localMembers` and `imports.Candidate.score`);
/// candidates whose type fits the expected type at the cursor are further multiplied by
/// `expected_boost` (see `Expected`). From high to low, keeping the collection order among equal
/// scores. Names in scope that do not match the input score 0, sort last, and are filtered by the
/// client. The expected type only changes the order of the returned candidates, not which ones are
/// kept (the limit applies to the unboosted scores)
fn rank(arena: Allocator, items: []Item, prefix: []const u8, expected: ?Expected) resolve.Error!void {
    var matcher: fuzzy.Matcher = try .init(arena, prefix);
    for (items) |*it| {
        if (it.weight != 0) it.score = ((try matcher.score(it.label)) orelse 0) * it.weight;
        if (expected) |x| if (it.score > 0 and try x.matches(it.origin)) {
            it.score *= expected_boost;
        };
    }
    std.mem.sort(Item, items, {}, higherScore);
    for (items, 0..) |*it, i| it.sort = try std.fmt.allocPrint(arena, "{d:0>5}", .{i});
}

fn higherScore(_: void, a: Item, b: Item) bool {
    return a.score > b.score;
}

pub const Description = struct {
    /// Signature (as in hover); for modules and files, the import expression
    detail: []const u8,
    /// Markdown: doc comment and location of the definition
    doc: []const u8,
};

/// Description shown when a completion item is selected (`completionItem/resolve`): the
/// definition referred to when completing in `from`
pub fn describe(r: *Resolver, from: FileId, target: imports.Target) resolve.Error!Description {
    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    switch (target) {
        .decl => |d| {
            const def: resolve.Def = .{ .item = .{ .file = d.file, .item = d.item } };
            const tv = try r.ctx.get(queries.DeclType, .{ .owner = try r.ownerKey(d.file, d.item) });
            const detail = try context.signature(r, def, tv);
            if (try context.doc(r, def)) |text| w.print("{s}\n\n", .{text}) catch return error.OutOfMemory;
            const text = (try r.ctx.get(database.syntax.SourceText, d.file)).text;
            var offset: usize = 0;
            if (try r.itemNode(d.file, d.item)) |node| {
                offset = if (ast.memberName(node, try r.inEnum(d.file, d.item))) |tok| tok.offset else node.offset;
            }
            const line = std.mem.count(u8, text[0..@min(offset, text.len)], "\n") + 1;
            w.print("Defined in `{s}:{d}`", .{ try imports.displayPath(r, from, d.file), line }) catch return error.OutOfMemory;
            return .{ .detail = detail, .doc = out.written() };
        },
        .file => |f| {
            const path = try imports.displayPath(r, from, f);
            const spec = try imports.importPath(r, from, f) orelse path;
            if (try fileDoc(r, f)) |text| w.print("{s}\n\n", .{text}) catch return error.OutOfMemory;
            w.print("File `{s}`", .{path}) catch return error.OutOfMemory;
            return .{ .detail = try std.fmt.allocPrint(r.arena, "@import(\"{f}\")", .{std.zig.fmtString(spec)}), .doc = out.written() };
        },
    }
}

/// The `//!` doc at the start of the file, cleaned up the same way as `///` docs (see
/// `ItemTree`); null when there is none
fn fileDoc(r: *Resolver, file: FileId) resolve.Error!?[]const u8 {
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    var out: std.ArrayList(u8) = .empty;
    var it = root.children();
    while (it.next()) |e| {
        if (e != .token) break;
        if (e.token.kind != .container_doc_comment) {
            if (isTrivia(e.token.kind)) continue;
            break;
        }
        var line = e.token.text["//!".len..];
        if (std.mem.startsWith(u8, line, " ")) line = line[1..];
        if (out.items.len != 0) try out.append(r.arena, '\n');
        try out.appendSlice(r.arena, std.mem.trimEnd(u8, line, "\r"));
    }
    return if (out.items.len == 0) null else out.items;
}

/// `cursor_owner` records the member found at the cursor, which auto-import reuses; in name
/// completion, `names` records the roots of the member paths of local values and the inference
/// result of the member at the cursor
fn completeVisible(r: *Resolver, file: FileId, offset: u32, cursor_owner: *imports.Owner, names: *NameContext) resolve.Error![]const Item {
    var out: Collector = .{ .arena = r.arena };
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    if (offset > text.len) return &.{};

    const literal = try commentOrString(r, file, offset);
    if (literal == .comment) return &.{};
    // The following contexts are mostly error nodes in the syntax tree (such as a lone `@` or an
    // unterminated string), so they are recognized directly from the source text
    if (literal == .none) if (builtinStart(text, offset)) |start| {
        const range: Item.Range = .{ .start = start, .end = identEnd(text, offset) };
        for (builtins.entries) |entry| try out.add(.{ .label = entry.name, .kind = .builtin, .replace = range, .detail = entry.signature, .doc = entry.documentation });
        return out.items.items;
    };
    if (importString(text, offset)) |start| {
        try importPaths(r, &out, file, text[start..offset], .{ .start = start, .end = offset });
        return out.items.items;
    }
    if (literal == .string) {
        try manifestPaths(r, &out, file, text, offset);
        return out.items.items;
    }

    cursor_owner.* = .{ .known = try r.ownerAt(file, offset, true) };
    const item = cursor_owner.known orelse return &.{};
    const node = try r.itemNode(file, item) orelse return &.{};
    const b = try r.body(file, item);
    const rel = offset - node.offset;

    if (labelStart(text, offset) != null) {
        var s: ?Body.ScopeId = b.scopeAt(rel);
        while (s) |id| : (s = b.scope(id).parent) if (b.scope(id).label) |l| try out.add(.{ .label = l.name, .kind = .label });
        return out.items.items;
    }

    // `lhs.` / `lhs.na`: the character before the cursor is inside a field access, and not
    // inside the left-hand expression
    if (rel > 0) if (b.exprAt(rel - 1)) |e| switch (b.expr(e)) {
        .field_access => |fa| if (rel - 1 >= b.range(fa.lhs).end) {
            out.member_mode = true;
            if (try r.evalNamespace(file, item, b, fa.lhs)) |ns| {
                try members(r, &out, ns, ns.file == file);
                return out.items.items;
            }
            // Via the type: fields and methods of the instance (inside the body of a generic
            // function, use the instance from a call site)
            const a = try context.atSeeded(r, file, offset, true) orelse return &.{};
            try typedMembers(r, &out, a.exprType(fa.lhs), file);
            return out.items.items;
        },
        else => {},
    };

    if (rel > 0) if (b.exprAt(rel - 1)) |e| if (b.expr(e) == .error_value) {
        out.member_mode = true;
        try errorNames(r, &out, file, offset, item, e);
        return out.items.items;
    };

    // `.` / `.na` (enum literals, decl literals): list members by the expected type; in an
    // initializer (`.{ .x = 1, .| }`), list the fields not yet assigned
    if (rel > 0) if (b.exprAt(rel - 1)) |e| if (b.expr(e) == .enum_literal) {
        out.member_mode = true;
        const a = try context.atSeeded(r, file, offset, true) orelse return &.{};
        if (initOf(b, e)) |init| {
            const x = b.expr(init).init;
            const ty = if (x.ty == null) a.literalExpected(init) orelse {
                for (try manifest.fieldCompletions(r, file, b, init)) |f| try out.add(.{ .label = f.name, .kind = .field, .doc = f.doc });
                return out.items.items;
            } else a.exprType(init).ty;
            try initFields(r, &out, ty, x.fields);
            return out.items.items;
        }
        try expectedMembers(r, &out, a.literalExpected(e) orelse return &.{}, file);
        return out.items.items;
    };

    // Names in scope: when the cursor immediately follows a name, use the scope of that name
    const scope = if (rel > 0) if (b.exprAt(rel - 1)) |e| switch (b.expr(e)) {
        .name_ref => b.expr_scopes[@backingInt(e)],
        else => b.scopeAt(rel),
    } else b.scopeAt(rel) else b.scopeAt(rel);
    // The kinds of local names come from the inference result of the member at the cursor
    // (inside a generic function body, from a call-site instance)
    names.at = try context.atSeeded(r, file, offset, true);
    const types: BindingTypes = if (names.at) |a| .{ .at = a } else .none;
    try locals(&out, r.ctx.db.env.ip, b, scope, null, types, &names.roots);

    const tree = try r.itemTree(file);
    var container = tree.items[item].container;
    var level: f32 = 0;
    while (true) : (level += 1) {
        // Members of inner containers rank above those of outer ones
        const weight = @max(min_container_weight, container_weight - container_step * level);
        try decls(r, &out, file, tree, container, true, weight);
        const parent = tree.containers[container].parent_item orelse break;
        // A container defined in a body: the local names of the enclosing member that are
        // visible at the position of the container
        const owner = try r.itemNode(file, parent) orelse break;
        const c_node = try r.containerNode(.{ .file = file, .container = container }) orelse break;
        const pb = try r.body(file, parent);
        const parent_res = try r.ctx.get(database.sema.Infer, .{ .owner = try r.ownerKey(file, parent), .mode = .full });
        try locals(&out, r.ctx.db.env.ip, pb, pb.scopeAt(c_node.offset - owner.offset), weight, .{ .res = parent_res }, &names.roots);
        container = tree.items[parent].container;
    }
    return out.items.items;
}

const ImportPrefix = struct {
    prefix: []const u8,
    range: Item.Range,
    escaped_prefix: ?[]const u8 = null,
    closed: bool = false,
};

/// Accepts only names in expressions; declaration names, member names, labels, and capture names
/// are not direct tokens of a name_ref.
fn importPrefix(arena: Allocator, root: SyntaxNode, text: []const u8, offset: u32) Allocator.Error!?ImportPrefix {
    const token = root.tokenAtOffset(offset - 1) orelse return null;
    if (token.kind != .identifier and token.kind != .invalid) return null;
    const parent = tokenParent(root, offset - 1);
    if (parent != .name_ref) return null;
    // Enum members and union(enum) tags have no colon, so the parser puts the name in the type
    // expression position of the container_field. They are still declaration names, and replacing
    // them with a qualified path would break the declaration.
    if (try isBareEnumOrUnionMember(arena, root, token.offset)) return null;
    const escaped = std.mem.startsWith(u8, token.text, "@\"");
    if (token.kind == .invalid and !escaped) return null;
    const spelling = if (token.kind == .invalid) std.mem.trimEnd(u8, token.text, "\r\n") else token.text;
    const token_end = token.offset + @as(u32, @intCast(spelling.len));
    if (offset <= token.offset or offset > token_end) return null;
    // An invalid token has no closing quote to delimit its end; keep the source after the cursor
    // instead of mistaking the following statements for part of the name and replacing them too.
    const end = if (token.kind == .invalid) offset else token_end;
    const raw = text[token.offset..offset];
    const closed = token.kind == .identifier and offset == end;
    var prefix = raw;
    if (escaped) {
        // Also match by the text typed so far when the cursor is inside the quotes; do not guess
        // the name when an escape sequence is cut off.
        if (raw.len <= 2) return null;
        const literal: []const u8 = if (closed) raw[1..] else blk: {
            const quoted = try arena.allocSentinel(u8, raw.len, 0);
            @memcpy(quoted[0 .. raw.len - 1], raw[1..]);
            quoted[raw.len - 1] = '"';
            // The added closing quote must not be swallowed by an unfinished escape; only pass a
            // single, lexically closed literal to the string decoder.
            var tokenizer = std.zig.Tokenizer.init(quoted);
            const checked = tokenizer.next();
            if (checked.tag != .string_literal or checked.loc.end != quoted.len) return null;
            break :blk quoted;
        };
        prefix = std.zig.string_literal.parseAlloc(arena, literal) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return null,
        };
    } else {
        if (std.zig.primitives.isPrimitive(token.text) or std.mem.eql(u8, token.text, "_")) return null;
    }
    if (prefix.len == 0) return null;
    return .{
        .prefix = prefix,
        .range = .{ .start = token.offset, .end = end },
        .escaped_prefix = if (escaped) raw else null,
        .closed = escaped and closed,
    };
}

/// Enum members and `union(enum)` tags are container_fields without a colon, with the name in the
/// type expression position; tuple fields of a struct have no colon either, but their type
/// expression is a real type reference, so they are not included.
fn isBareEnumOrUnionMember(arena: Allocator, root: SyntaxNode, offset: u32) Allocator.Error!bool {
    const path = try root.coveringPath(arena, offset);
    if (path.len < 3) return false;
    if (path[path.len - 1].kind() != .name_ref) return false;
    const field = path[path.len - 2];
    if (field.kind() != .container_field) return false;
    const container = path[path.len - 3];
    if (container.kind() != .container_decl) return false;
    const keyword = (ast.ContainerDecl{ .syntax = container }).keyword() orelse return false;
    if (keyword != .@"enum" and keyword != .@"union") return false;
    const name = (ast.ContainerField{ .syntax = field }).enumName() orelse return false;
    return name.offset == offset;
}

/// The client filters from the start of the replace range; keep the quotes and escape spelling
/// that the user typed instead of returning only the decoded name.
fn completionFilter(arena: Allocator, name: ImportPrefix, target: []const u8) Allocator.Error![]const u8 {
    const raw = name.escaped_prefix orelse return target;
    // A candidate matched by path is filtered by its path (see `imports.Builder.filterOf`)
    if (!std.ascii.startsWithIgnoreCase(target, name.prefix)) return target;
    const closed = name.closed;
    return std.fmt.allocPrint(arena, "{s}{f}{s}", .{
        raw, std.zig.fmtString(target[name.prefix.len..]), if (closed) "" else "\"",
    });
}

fn tokenParent(node: SyntaxNode, offset: u32) @import("../syntax/kind.zig").SyntaxKind {
    var children = node.children();
    while (children.next()) |child| {
        if (!child.range().contains(offset)) continue;
        return switch (child) {
            .token => node.kind(),
            .node => |inner| tokenParent(inner, offset),
        };
    }
    return node.kind();
}

const Collector = struct {
    arena: Allocator,
    items: std.ArrayList(Item) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Members / fields after `.`: names of primitive types and primitive values need no quoting
    /// (`S.u8`)
    member_mode: bool = false,

    /// Inner names shadow outer names of the same name. Names in scope are always quoted per
    /// `fmtId` (primitive types, names with special characters); members after `.` may use
    /// primitive names.
    fn add(c: *Collector, item: Item) Allocator.Error!void {
        if (item.label.len == 0) return;
        if ((try c.seen.getOrPut(c.arena, item.label)).found_existing) return;
        var out = item;
        const is_name = switch (item.kind) {
            .builtin, .module, .file, .folder => false,
            else => true,
        };
        if (is_name) out.label = try std.fmt.allocPrint(c.arena, "{f}", .{std.zig.fmtIdFlags(item.label, .{ .allow_primitive = c.member_mode })});
        try c.items.append(c.arena, out);
    }
};

/// Source weights of names in scope (see `rank`): local names, parameters and members of the
/// enclosing container come in that order, and members of outer containers lose another
/// `container_step` per level; all are above auto-import candidates accessed through a namespace
/// (`imports.visible_weight`)
const local_weight = 1.0;
const param_weight = 0.98;
const container_weight = 0.94;
const container_step = 0.02;
const min_container_weight = 0.86;

/// Types of bindings: from `At` for the member at the cursor, and from the inference result for
/// an enclosing function
const BindingTypes = union(enum) {
    none,
    at: context.At,
    res: *const infer.Result,

    fn of(t: BindingTypes, id: Body.BindingId) TypedValue {
        return switch (t) {
            .none => .unknown,
            .at => |a| a.bindingType(id),
            .res => |res| if (@backingInt(id) < res.bindings.len) res.bindings[@backingInt(id)] else .unknown,
        };
    }
};

/// When `weight` is null, the weight follows the kind of the binding; otherwise every name gets
/// `weight` (names in an enclosing function). Local values that are not shadowed are recorded in
/// `roots` (see `rootOf`)
fn locals(out: *Collector, ip: *InternPool, b: *const Body, from: Body.ScopeId, weight: ?f32, types: BindingTypes, roots: *std.ArrayList(Root)) Allocator.Error!void {
    var s: ?Body.ScopeId = from;
    while (s) |id| : (s = b.scope(id).parent) {
        for (b.scope(id).bindings) |bid| {
            const binding = b.binding(bid);
            const tv = types.of(bid);
            if (!out.seen.contains(binding.name)) if (rootOf(binding, tv, weight != null)) |root| try roots.append(out.arena, root);
            try out.add(.{
                .label = binding.name,
                .kind = kindOf(symbol_kind.ofBinding(ip, binding, tv)),
                .weight = weight orelse if (binding.kind == .param) param_weight else local_weight,
                .origin = .{ .value = tv },
            });
        }
    }
}

/// A local value as the root of member paths: not when its value is a type or its type cannot be
/// computed; in an enclosing function (`outer`), only comptime-known values are, since functions in
/// a container cannot access the runtime values of the enclosing function
fn rootOf(binding: Body.Binding, tv: TypedValue, outer: bool) ?Root {
    // A bare `_` introduces no name
    if (binding.range.end - binding.range.start == 1 and std.mem.eql(u8, binding.name, "_")) return null;
    if (tv.ty == .unknown or tv.isType()) return null;
    if (outer) {
        const known = if (tv.val) |v| v != .unknown and v != .runtime else false;
        if (binding.kind == .local_var or !(known or (binding.kind == .param and binding.is_comptime))) return null;
    }
    return .{ .name = binding.name, .ty = tv.ty, .mutable = binding.kind == .local_var };
}

fn decls(r: *Resolver, out: *Collector, file: FileId, tree: *const ItemTree, container: u32, private: bool, weight: f32) resolve.Error!void {
    const is_enum = tree.containers[container].kind == .@"enum";
    for (tree.containerMembers(container)) |m| {
        const it = tree.items[m];
        const name = it.name orelse continue;
        switch (it.kind) {
            .@"fn", .@"const", .@"var" => {},
            // Fields are not names in scope; enum members can be accessed through the type
            .field => if (!is_enum or private) continue,
            .@"test", .@"comptime", .zon => continue,
        }
        if (!private and it.kind != .field and !it.flags.is_pub) continue;
        const kind = kindOf(try symbol_kind.ofDecl(r, file, m));
        const decl: imports.Target = .{ .decl = .{ .file = file, .item = m } };
        try out.add(.{ .label = name, .kind = kind, .doc = it.doc, .target = if (it.kind == .@"fn") decl else null, .weight = weight, .origin = .{ .target = decl } });
    }
}

/// Kind of a completion item: a variable that cannot be modified is a constant
fn kindOf(symbol: symbol_kind.Symbol) Item.Kind {
    return switch (symbol.kind) {
        .namespace => .namespace,
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .type => .type,
        .function => .function,
        .method => .method,
        .variable => if (symbol.readonly) .constant else .variable,
        .field => .field,
        .enum_member => .enum_member,
        .parameter => .param,
        .type_parameter => .type_param,
    };
}

/// Lists members by type: declarations when the value is a type; fields and methods for
/// instances (including single pointers); slices and arrays have len
fn typedMembers(r: *Resolver, out: *Collector, tv: TypedValue, from: FileId) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    if (tv.asType()) |t| {
        // Constructed enums (`@Enum`, the tag enum of a union(enum)): members
        switch (ip.key(t)) {
            .reified_type, .union_tag_type => {
                for (try eval.enumMemberNames(r, t)) |name| try out.add(.{ .label = name, .kind = .enum_member });
                return;
            },
            // Error set (after `Error.`): its error names
            .error_set_type => |names| {
                for (names) |name| try out.add(.{ .label = name, .kind = .enum_member });
                return;
            },
            else => {},
        }
        const ns = try queries.namespaceOfType(r, t) orelse return;
        return members(r, out, ns, ns.file == from);
    }
    var t = tv.ty;
    // A single pointer is dereferenced automatically once: len of `*[N]T`, fields and methods of
    // `*S`, len and ptr of `*[]T`
    switch (ip.key(t)) {
        .ptr_type => |p| if (p.size == .one) {
            t = p.child;
        },
        else => {},
    }
    switch (ip.key(t)) {
        .ptr_type => |p| {
            // Single pointers to pointers and many-item pointers have no members
            if (p.size == .slice) {
                try out.add(.{ .label = "len", .kind = .field, .detail = "usize" });
                try out.add(.{ .label = "ptr", .kind = .field });
            }
            return;
        },
        .array_type => return out.add(.{ .label = "len", .kind = .field, .detail = "usize" }),
        // Tuples, anonymous structs, constructed structs and unions: fields
        .tuple_type, .anon_struct_type, .reified_type => {
            for (try eval.fieldNames(r, t)) |f| try out.add(.{ .label = f.name, .kind = .field, .detail = if (f.ty != .unknown) try render.typeAlloc(r, f.ty) else null });
            if (ip.key(t) == .tuple_type) try out.add(.{ .label = "len", .kind = .field, .detail = "usize" });
            return;
        },
        else => {},
    }
    const ns = try queries.namespaceOfType(r, t) orelse return;
    const tree = try r.itemTree(ns.file);
    const same_file = ns.file == from;
    for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        const name = it.name orelse continue;
        switch (it.kind) {
            .field => {
                const fty = (try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = ns.file, .item = it.ast_id }, .inst = queries.instOfType(r.ctx.db.env.ip, t) })).ty;
                try out.add(.{ .label = name, .kind = .field, .doc = it.doc, .detail = if (fty != .unknown) try render.typeAlloc(r, fty) else null });
            },
            .@"fn" => if (same_file or it.flags.is_pub) try out.add(.{ .label = name, .kind = kindOf(try symbol_kind.ofDecl(r, ns.file, m)), .doc = it.doc, .target = .{ .decl = .{ .file = ns.file, .item = m } } }),
            // Function aliases (`pub const isPowerPC = isPowerpc;`) can also be called as methods;
            // when selected, they show the signature of the aliased function
            .@"const" => if (same_file or it.flags.is_pub) {
                const ctv = try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = ns.file, .item = it.ast_id }, .inst = queries.instOfType(ip, t) });
                if (ip.key(ctv.ty) == .fn_type) try out.add(.{ .label = name, .kind = .function, .doc = it.doc, .target = try fnTarget(r, ctv) });
            },
            else => {},
        }
    }
}

/// After `.`: enum members and union fields of the expected type (`T` for `?T`), and
/// declarations that can serve as decl literals (constants of type `T`, functions returning `T`
/// or `!T`; also listed when their type cannot be inferred)
fn expectedMembers(r: *Resolver, out: *Collector, ty: Index, from: FileId) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    // Matching the compiler, strip error unions and optionals from the result type
    // (`fn f() !Color { return .red; }`)
    var t = ty;
    while (true) t = switch (ip.key(t)) {
        .error_union_type => |eu| eu.payload,
        .optional_type => |c| c,
        else => break,
    };
    switch (ip.key(t)) {
        .reified_type, .union_tag_type => {
            for (try eval.enumMemberNames(r, t)) |name| try out.add(.{ .label = name, .kind = .enum_member });
            return;
        },
        .container_type => {},
        else => return,
    }
    const ns = try queries.namespaceOfType(r, t) orelse return;
    const tree = try r.itemTree(ns.file);
    const kind = tree.containers[ns.container].kind;
    const inst = queries.instOfType(ip, t);
    for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        const name = it.name orelse continue;
        switch (it.kind) {
            .field => switch (kind) {
                .@"enum" => try out.add(.{ .label = name, .kind = .enum_member, .doc = it.doc }),
                .@"union" => try out.add(.{ .label = name, .kind = .field, .doc = it.doc }),
                else => {},
            },
            .@"const", .@"fn" => {
                if (ns.file != from and !it.flags.is_pub) continue;
                const decl_ty = (try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = ns.file, .item = it.ast_id }, .inst = inst })).ty;
                if (!producesType(ip, decl_ty, t, it.kind == .@"fn")) continue;
                const is_fn = it.kind == .@"fn";
                try out.add(.{ .label = name, .kind = kindOf(try symbol_kind.ofDecl(r, ns.file, m)), .doc = it.doc, .target = if (is_fn) .{ .decl = .{ .file = ns.file, .item = m } } else null });
            },
            else => {},
        }
    }
}

/// Whether a declaration can serve as a decl literal of type `t`: a constant of type `t`, or a
/// function returning `t` or `!t`; an unknown type counts as yes
fn producesType(ip: *InternPool, decl_ty: Index, t: Index, is_fn: bool) bool {
    if (decl_ty == .unknown) return true;
    if (!is_fn) return decl_ty == t;
    const ret = switch (ip.key(decl_ty)) {
        .fn_type => |f| f.ret,
        else => return false,
    };
    if (ret == .unknown or ret == t) return true;
    return switch (ip.key(ret)) {
        .error_union_type => |eu| eu.payload == t or eu.payload == .unknown,
        else => false,
    };
}

/// The function declaration that a function value refers to
fn fnTarget(r: *Resolver, tv: TypedValue) resolve.Error!?imports.Target {
    const v = tv.val orelse return null;
    const f = switch (r.ctx.db.env.ip.key(v)) {
        .fn_value => |f| f,
        else => return null,
    };
    const def = try context.defOfKey(r, .{ .file = f.file, .item = f.decl }) orelse return null;
    return .{ .decl = .{ .file = def.item.file, .item = def.item.item } };
}

/// Weight of the member paths of local values, also multiplied by the depth factor of the path (see
/// `imports.segmentFactor`): below the names in scope (at least `min_container_weight`) and above
/// the candidates accessed through a namespace (`imports.visible_weight` times the depth factor)
const local_member_weight = 0.9;

/// Root of the member paths of local values (see `localMembers`): a local value that is visible at
/// the cursor and not shadowed
const Root = struct {
    name: []const u8,
    ty: Index,
    /// A local var: values accessed through it can be modified
    mutable: bool,
};

/// What `completeVisible` computes in name completion and `complete` reuses
const NameContext = struct {
    /// From the innermost outward
    roots: std.ArrayList(Root) = .empty,
    /// The member at the cursor and its inference result (with a call-site instance inside a
    /// generic function body), for computing the expected type
    at: ?context.At = null,
};

/// The value a member path refers to: its type, and whether it can be modified (methods that
/// receive `*T` require that it can)
const Place = struct {
    ty: Index,
    mutable: bool,

    /// A single-item pointer is dereferenced once automatically; whether the value it points to can
    /// be modified depends on the pointer
    fn deref(p: Place, ip: *InternPool) Place {
        return switch (ip.key(p.ty)) {
            .ptr_type => |ptr| if (ptr.size == .one) .{ .ty = ptr.child, .mutable = !ptr.is_const } else p,
            else => p,
        };
    }
};

/// A member of a value; the types of container fields and the signatures of methods are computed
/// only when used
const Member = struct {
    name: []const u8,
    doc: ?[]const u8 = null,
    what: union(enum) {
        /// A field whose type is known: `len` / `ptr` of slices and arrays, and the fields of
        /// tuples, anonymous structs, and reified types
        typed: Index,
        /// A field of a container
        field: Decl,
        /// A function in a container, or a const whose value may be a function (`Decl.alias`)
        method: Decl,
    },

    /// A member of a container; `inst` is the instance of the container
    const Decl = struct { file: FileId, item: u32, ast_id: ItemTree.AstId, inst: ?Index, alias: bool = false };
};

/// A matched member path: `root.leaf`, or `root.mid.leaf` / `root.mid().leaf` through a middle
/// segment
const MemberPath = struct {
    score: f32,
    /// The name starts with the input in the same case: preferred among equal scores
    case_exact: bool,
    root: []const u8,
    mid: ?Step,
    /// The value holding the leaf (dereferenced)
    holder: Place,
    leaf: Member,

    const Step = struct { name: []const u8, call: bool };

    fn higher(_: void, a: MemberPath, b: MemberPath) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.case_exact and !b.case_exact;
    }
};

const LocalMembers = struct { items: []const Item, incomplete: bool };

/// Member paths of local values: fields and methods that can be called there (`a.b`), as well as
/// members of fields and of the results of methods that take only self (`a.b.c`, `a.b().c`). The
/// whole path is fuzzy-matched against the input, whether or not the leading segments match; the
/// score is the match score multiplied by `local_member_weight` and the depth factor. Items are
/// built from the highest score down (checking that methods can be called there) until `limit` of
/// them are built; the list is `incomplete` when another path left out could be built
fn localMembers(r: *Resolver, file: FileId, roots: []const Root, name: ImportPrefix, limit: usize) resolve.Error!LocalMembers {
    if (roots.len == 0) return .{ .items = &.{}, .incomplete = false };
    const ip = r.ctx.db.env.ip;
    var search: MemberSearch = .{ .r = r, .file = file, .prefix = name.prefix, .matcher = try .init(r.arena, name.prefix) };
    for (roots) |root| {
        const holder = (Place{ .ty = root.ty, .mutable = root.mutable }).deref(ip);
        for (try search.membersOf(holder.ty)) |m| {
            try search.consider(root.name, null, holder, m);
            const next = try search.through(m, holder) orelse continue;
            const step: MemberPath.Step = .{ .name = m.name, .call = m.what == .method };
            for (try search.membersOf(next.ty)) |leaf| try search.consider(root.name, step, next, leaf);
        }
    }
    std.mem.sort(MemberPath, search.found.items, {}, MemberPath.higher);
    var items: std.ArrayList(Item) = .empty;
    for (search.found.items, 0..) |p, i| {
        if (items.items.len >= limit) {
            // Incomplete only when a path left out can be built (methods that cannot be called
            // there are not items)
            for (search.found.items[i..]) |rest| {
                if (try search.construct(rest, name) != null) return .{ .items = items.items, .incomplete = true };
            }
            break;
        }
        if (try search.construct(p, name)) |item| try items.append(r.arena, item);
    }
    return .{ .items = items.items, .incomplete = false };
}

const MemberSearch = struct {
    r: *Resolver,
    file: FileId,
    prefix: []const u8,
    matcher: fuzzy.Matcher,
    found: std.ArrayList(MemberPath) = .empty,
    /// Members recorded by type: values of the same type appear through several paths
    members: std.AutoHashMapUnmanaged(Index, []const Member) = .empty,

    fn consider(s: *MemberSearch, root: []const u8, mid: ?MemberPath.Step, holder: Place, leaf: Member) Allocator.Error!void {
        const match = if (mid) |m|
            try s.matcher.scoreJoined(&.{ root, ".", m.name, ".", leaf.name })
        else
            try s.matcher.scoreJoined(&.{ root, ".", leaf.name });
        const score = match orelse return;
        try s.found.append(s.r.arena, .{
            .score = score * local_member_weight * imports.segmentFactor(if (mid == null) 2 else 3),
            .case_exact = std.mem.startsWith(u8, leaf.name, s.prefix),
            .root = root,
            .mid = mid,
            .holder = holder,
            .leaf = leaf,
        });
    }

    /// Members of a value (dereferenced): fields, and the functions and consts in this file or pub
    /// (whether a const is a function is known only when the item is built). Values that are not
    /// containers, tuples, slices, or arrays have no members (`?T`, `E!T`, single-item pointers to
    /// pointers, many-item pointers, and so on)
    fn membersOf(s: *MemberSearch, t: Index) resolve.Error![]const Member {
        if (s.members.get(t)) |known| return known;
        const r = s.r;
        const ip = r.ctx.db.env.ip;
        var out: std.ArrayList(Member) = .empty;
        switch (ip.key(t)) {
            .ptr_type => |p| if (p.size == .slice) {
                try out.append(r.arena, .{ .name = "len", .what = .{ .typed = .usize_type } });
                const many = try ip.get(.{ .ptr_type = .{ .child = p.child, .size = .many, .is_const = p.is_const, .sentinel = p.sentinel } });
                try out.append(r.arena, .{ .name = "ptr", .what = .{ .typed = many } });
            },
            .array_type => try out.append(r.arena, .{ .name = "len", .what = .{ .typed = .usize_type } }),
            .tuple_type, .anon_struct_type, .reified_type => {
                for (try eval.fieldNames(r, t)) |f| try out.append(r.arena, .{ .name = f.name, .what = .{ .typed = f.ty } });
                if (ip.key(t) == .tuple_type) try out.append(r.arena, .{ .name = "len", .what = .{ .typed = .usize_type } });
            },
            .container_type => |c| if (try queries.namespaceOfType(r, t)) |ns| {
                const tree = try r.itemTree(ns.file);
                const fields = c.kind != .@"enum" and c.kind != .@"opaque";
                for (tree.containerMembers(ns.container)) |m| {
                    const it = tree.items[m];
                    const name = it.name orelse continue;
                    const decl: Member.Decl = .{ .file = ns.file, .item = m, .ast_id = it.ast_id, .inst = c.inst, .alias = it.kind == .@"const" };
                    switch (it.kind) {
                        .field => if (fields) try out.append(r.arena, .{ .name = name, .doc = it.doc, .what = .{ .field = decl } }),
                        .@"fn", .@"const" => if (ns.file == s.file or it.flags.is_pub) try out.append(r.arena, .{ .name = name, .doc = it.doc, .what = .{ .method = decl } }),
                        else => {},
                    }
                }
            },
            else => {},
        }
        try s.members.put(r.arena, t, out.items);
        return out.items;
    }

    /// The value (dereferenced) reached through the first-level member `m`, whose members form the
    /// second level: the value of a field, or the result of a method that takes only self and
    /// returns a container or a single-item pointer (when a pointer is returned, whether the value
    /// can be modified depends on the pointer; a returned value is a temporary that cannot be
    /// modified)
    fn through(s: *MemberSearch, m: Member, holder: Place) resolve.Error!?Place {
        const r = s.r;
        const ip = r.ctx.db.env.ip;
        switch (m.what) {
            .typed => |t| return (Place{ .ty = t, .mutable = holder.mutable }).deref(ip),
            .field => |f| return (Place{ .ty = (try declType(r, f)).ty, .mutable = holder.mutable }).deref(ip),
            .method => |f| {
                if (f.alias or !try onlySelf(r, f.file, f.item)) return null;
                const sig = switch (ip.key((try declType(r, f)).ty)) {
                    .fn_type => |sig| sig,
                    else => return null,
                };
                if (sig.params.len != 1 or sig.varargs or !receives(ip, sig.params[0], holder)) return null;
                return switch (ip.key(sig.ret)) {
                    .ptr_type => |p| if (p.size == .one) .{ .ty = p.child, .mutable = !p.is_const } else null,
                    .container_type, .tuple_type, .anon_struct_type, .reified_type => .{ .ty = sig.ret, .mutable = false },
                    else => null,
                };
            },
        }
    }

    /// The completion item: a method must be callable on the value holding the leaf; a field
    /// carries its type
    fn construct(s: *MemberSearch, p: MemberPath, name: ImportPrefix) resolve.Error!?Item {
        const r = s.r;
        const ip = r.ctx.db.env.ip;
        var item: Item = .{ .label = "", .kind = .field, .doc = p.leaf.doc, .replace = name.range, .score = p.score };
        switch (p.leaf.what) {
            .typed => |t| {
                item.detail = if (t != .unknown) try render.typeAlloc(r, t) else null;
                item.origin = .{ .value = .{ .ty = t } };
            },
            .field => |f| {
                const t = (try declType(r, f)).ty;
                item.detail = if (t != .unknown) try render.typeAlloc(r, t) else null;
                item.origin = .{ .value = .{ .ty = t } };
            },
            .method => |f| {
                const tv = try declType(r, f);
                const sig = switch (ip.key(tv.ty)) {
                    .fn_type => |sig| sig,
                    else => return null,
                };
                if (sig.params.len == 0 or !receives(ip, sig.params[0], p.holder)) return null;
                // Classified like the same declaration after `.` (a function in a file is Function)
                item.kind = kindOf(try symbol_kind.ofDecl(r, f.file, f.item));
                item.target = if (f.alias) try fnTarget(r, tv) else .{ .decl = .{ .file = f.file, .item = f.item } };
                item.origin = .{ .value = tv };
            },
        }
        var label: std.Io.Writer.Allocating = .init(r.arena);
        const w = &label.writer;
        w.print("{f}", .{std.zig.fmtId(p.root)}) catch return error.OutOfMemory;
        if (p.mid) |m| w.print(".{f}{s}", .{ std.zig.fmtIdP(m.name), if (m.call) "()" else "" }) catch return error.OutOfMemory;
        w.print(".{f}", .{std.zig.fmtIdP(p.leaf.name)}) catch return error.OutOfMemory;
        item.label = label.written();
        // The same as for auto-import candidates (see `imports.Builder.filterOf`)
        const filter = if (std.ascii.startsWithIgnoreCase(p.leaf.name, name.prefix)) p.leaf.name else item.label;
        item.filter = try completionFilter(r.arena, name, filter);
        return item;
    }
};

fn declType(r: *Resolver, d: Member.Decl) resolve.Error!TypedValue {
    return r.ctx.get(queries.DeclType, .{ .owner = .{ .file = d.file, .item = d.ast_id }, .inst = d.inst });
}

/// Whether the first parameter of a method can receive the value at `holder`: the parameter is the
/// enclosing container, a `*const` pointer to it, or a `*T` pointer to it when the value can be
/// modified
fn receives(ip: *InternPool, param: Index, holder: Place) bool {
    if (sameContainer(ip, param, holder.ty)) return true;
    return switch (ip.key(param)) {
        .ptr_type => |p| p.size == .one and sameContainer(ip, p.child, holder.ty) and (p.is_const or holder.mutable),
        else => false,
    };
}

/// The same container definition: method signatures are inferred in the instance of their
/// container
fn sameContainer(ip: *InternPool, a: Index, b: Index) bool {
    const x = switch (ip.key(a)) {
        .container_type => |c| c,
        else => return false,
    };
    const y = switch (ip.key(b)) {
        .container_type => |c| c,
        else => return false,
    };
    return x.file == y.file and x.ast_id == y.ast_id;
}

/// The function declaration has exactly one parameter: a method that takes only self (judged by
/// syntax, so that the signatures of the other methods need not be computed)
fn onlySelf(r: *Resolver, file: FileId, item: u32) resolve.Error!bool {
    if ((try r.itemTree(file)).items[item].kind != .@"fn") return false;
    const node = try r.itemNode(file, item) orelse return false;
    const proto = (ast.cast(ast.FnDecl, node) orelse return false).proto() orelse return false;
    var params = proto.params();
    var n: usize = 0;
    while (params.next()) |_| n += 1;
    return n == 1;
}

/// The scores of candidates whose types fit the expected type at the cursor are multiplied by this
/// factor (see `rank`): it exceeds the ratio between any two weights of names in scope, so fitting
/// members of outer containers rank before local names that do not fit
const expected_boost = 1.25;

/// The expected type of the name at the cursor (see `expectedAt`), and the context needed to decide
/// whether a candidate fits it
const Expected = struct {
    r: *Resolver,
    ty: Index,
    /// The instance of the member at the cursor (the call-site instance inside a generic function
    /// body), for computing the types of declarations in scope
    inst: ?Index,

    /// Whether the type of the candidate fits the expected type (see `fits`); the types of
    /// declarations and files are computed only here
    fn matches(x: Expected, origin: Item.Origin) resolve.Error!bool {
        const tv: TypedValue = switch (origin) {
            .none => return false,
            .value => |tv| tv,
            .target => |t| switch (t) {
                .decl => |d| try queries.defType(x.r, .{ .item = .{ .file = d.file, .item = d.item } }, null, x.inst),
                .file => |f| try queries.importValue(x.r, f),
            },
        };
        return fits(x.r.ctx.db.env.ip, x.ty, tv.ty);
    }
};

/// The expected type of the name at the cursor (see `expectedOf`). Only concrete types count:
/// anytype parameters and parameters that depend on comptime parameters have none, and none is
/// taken when the statement at the cursor has syntax errors (see `wellFormed`)
fn expectedAt(r: *Resolver, file: FileId, offset: u32, at: ?context.At) resolve.Error!?Expected {
    const a = at orelse return null;
    if (a.rel == 0) return null;
    const e = a.body.exprAt(a.rel - 1) orelse return null;
    if (a.body.expr(e) != .name_ref) return null;
    const want = try expectedOf(r, a, e) orelse return null;
    if (!value.isConcrete(a.ip, want) or !try wellFormed(r, file, offset)) return null;
    return .{ .r = r, .ty = want, .inst = if (a.seeded) |s| s.inst else null };
}

/// The expected type of the expression `e`, computed from the parent expression and the inference
/// result: a call argument takes the type of the called function's parameter; `const x: T = e`
/// (including declarations in containers and default values of fields) takes the annotated type;
/// `return e` takes the return type of the function; `.f = e` in an initializer takes the type of
/// the field; `lhs = e` takes the type of the left-hand side; a comparison takes the type of the
/// other side; `@as(T, e)` takes `T`. The branches of `if`, `switch`, `orelse`, and `catch`, the
/// value of `break :label`, and `comptime e` take the expected type of the expression they produce
fn expectedOf(r: *Resolver, a: context.At, e: Body.ExprId) resolve.Error!?Index {
    const b = a.body;
    for (b.exprs, 0..) |x, i| {
        const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
        switch (x) {
            .call => |c| for (c.args, 0..) |arg, n| {
                if (arg == e) return argType(r, a, c.callee, n);
            },
            .init => |init| for (init.fields) |f| {
                if (f.value == e) return initFieldType(r, a, id, f.name orelse return null);
            },
            .@"return" => |v| if (v == e) {
                if ((try r.itemTree(a.file)).items[a.item].kind != .@"fn") return null;
                return a.exprType(b.type_expr orelse return null).asType();
            },
            .assign => |s| if (s.rhs == e) return if (s.op == .equal) a.exprType(s.lhs).ty else null,
            .binary => |s| {
                if (isComparison(s.op) and (s.lhs == e or s.rhs == e)) {
                    return comparedType(r, a.exprType(if (s.lhs == e) s.rhs else s.lhs).ty);
                }
                if (s.op == .keyword_orelse and s.rhs == e) return expectedOf(r, a, id);
            },
            .builtin_call => |c| if (std.mem.eql(u8, c.name, "@as") and c.args.len == 2 and c.args[1] == e) {
                return a.exprType(c.args[0]).asType();
            },
            .@"if" => |s| if (s.then == e or s.@"else" == e) return expectedOf(r, a, id),
            .@"switch" => |s| for (s.prongs) |prong| {
                if (prong.body == e) return expectedOf(r, a, id);
            },
            .@"catch" => |s| if (s.rhs == e) return expectedOf(r, a, id),
            .@"comptime" => |inner| if (inner == e) return expectedOf(r, a, id),
            .@"break" => |s| if (s.value == e) {
                return expectedOf(r, a, labeledBlock(b, id, s.label orelse return null) orelse return null);
            },
            else => {},
        }
    }
    for (b.bindings) |binding| if (binding.init == e) return a.exprType(binding.ty orelse return null).asType();
    if (b.value == e) return a.exprType(b.type_expr orelse return null).asType();
    return null;
}

/// The innermost block labeled `label` that contains the expression `e`
fn labeledBlock(b: *const Body, e: Body.ExprId, label: []const u8) ?Body.ExprId {
    const range = b.range(e);
    var found: ?Body.ExprId = null;
    for (b.exprs, 0..) |x, i| {
        const block = switch (x) {
            .block => |block| block,
            else => continue,
        };
        const l = block.label orelse continue;
        if (!std.mem.eql(u8, l, label)) continue;
        const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
        const r = b.range(id);
        if (r.start > range.start or r.end < range.end) continue;
        if (found) |f| if (b.range(f).start > r.start) continue;
        found = id;
    }
    return found;
}

/// The expected type of argument `n` of a call: the type of the called function's parameter. A
/// method call skips self (see `context.callee`); when the member called through a value cannot be
/// resolved, whether it binds self is unknown and there is no expected type
fn argType(r: *Resolver, a: context.At, callee: Body.ExprId, n: usize) resolve.Error!?Index {
    const ip = a.ip;
    const f = switch (ip.key(a.exprType(callee).ty)) {
        .fn_type => |f| f,
        .ptr_type => |p| if (p.size == .one) switch (ip.key(p.child)) {
            .fn_type => |f| f,
            else => return null,
        } else return null,
        else => return null,
    };
    const target = try context.callee(r, a, callee);
    if (target == null and a.body.expr(callee) == .field_access) return null;
    const skip: usize = if (target) |t| @intFromBool(t.bound) else 0;
    return if (n + skip < f.params.len) f.params[n + skip] else null;
}

/// The type of the field `name` in the initializer `init_e`: the field of the initializer's type
/// (`T` for `?T` and `E!T`)
fn initFieldType(r: *Resolver, a: context.At, init_e: Body.ExprId, name: []const u8) resolve.Error!?Index {
    const ip = a.ip;
    var t = if (a.body.expr(init_e).init.ty != null) a.exprType(init_e).ty else a.literalExpected(init_e) orelse return null;
    while (true) switch (ip.key(t)) {
        .optional_type => |c| t = c,
        .error_union_type => |eu| t = eu.payload,
        else => break,
    };
    return eval.fieldType(r, t, name);
}

fn isComparison(op: SyntaxKind) bool {
    return switch (op) {
        .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal => true,
        else => false,
    };
}

/// The type of one side of a comparison as the expected type of the other side: a tagged union is
/// compared with its tag (`u == .none`); comptime numbers, enum literals, null, and undefined have
/// no definite type
fn comparedType(r: *Resolver, t: Index) resolve.Error!?Index {
    switch (t) {
        .unknown, .comptime_int_type, .comptime_float_type, .enum_literal_type, .null_type, .undefined_type => return null,
        else => {},
    }
    const is_union = switch (r.ctx.db.env.ip.key(t)) {
        .container_type => |c| c.kind == .@"union",
        .reified_type => |rt| rt.kind == .@"union",
        else => false,
    };
    return if (is_union) eval.unionTag(r, t) else t;
}

/// Whether the structure of the statement at the cursor (the innermost item of a block, file, or
/// container that contains the cursor) can be trusted: error recovery can produce a wrong
/// structure, e.g. after an unclosed call, `const x: u32 = cd` on the next line is recovered as an
/// error node and `u32 = cd`. It cannot be trusted when there is a syntax error inside the
/// statement, the previous item is an error node, or the call or initializer at the cursor is not
/// closed; an error at the start of the statement belongs to the previous statement (a missing
/// `;`), and errors at its end or after it are outside the statement
fn wellFormed(r: *Resolver, file: FileId, offset: u32) resolve.Error!bool {
    const parse = try r.ctx.get(database.syntax.ParseFile, file);
    const path = try parse.rootNode().coveringPath(r.arena, offset - 1);
    var i = path.len;
    const stmt = while (i > 1) {
        i -= 1;
        switch (path[i - 1].kind()) {
            .block, .source_file, .container_decl => break path[i],
            else => {},
        }
    } else return false;
    if (stmt.kind() == .error_node) return false;
    var siblings = path[i - 1].children();
    var prev: ?SyntaxNode = null;
    while (siblings.nextNode()) |n| {
        if (n.offset == stmt.offset and n.green == stmt.green) break;
        prev = n;
    }
    if (prev) |p| if (p.kind() == .error_node) return false;
    const range = stmt.range();
    for (parse.errors) |err| if (err.offset > range.start and err.offset < range.end) return false;
    for (path[i..]) |n| switch (n.kind()) {
        .arg_list => if (n.childToken(.r_paren) == null) return false,
        .init_list => if (n.childToken(.r_brace) == null) return false,
        else => {},
    };
    return true;
}

/// Whether a candidate of type `have` can be a value of the expected type `want`, counting only
/// what can be decided exactly: the same type; `T` when `?T` or `E!T` is expected; `*T` as
/// `*const T` and `[]T` as `[]const T`; functions (including function pointers) whose return value
/// fits. Other conversions (integer widening, comptime_int, and so on) do not count
fn fits(ip: *InternPool, want: Index, have: Index) bool {
    if (coerces(ip, want, have)) return true;
    const f = switch (ip.key(have)) {
        .fn_type => |f| f,
        .ptr_type => |p| if (p.size == .one) switch (ip.key(p.child)) {
            .fn_type => |f| f,
            else => return false,
        } else return false,
        else => return false,
    };
    return coerces(ip, want, f.ret);
}

fn coerces(ip: *InternPool, want: Index, have: Index) bool {
    if (have == .unknown) return false;
    if (value.eqlTypes(ip, want, have) orelse false) return true;
    switch (ip.key(want)) {
        .optional_type => |child| return coerces(ip, child, have),
        .error_union_type => |eu| return coerces(ip, eu.payload, have),
        .ptr_type => |w| {
            const h = switch (ip.key(have)) {
                .ptr_type => |h| h,
                else => return false,
            };
            if (w.size != h.size or (w.size != .one and w.size != .slice)) return false;
            if (!w.is_const or h.is_const or !std.meta.eql(w.sentinel, h.sentinel)) return false;
            return value.eqlTypes(ip, w.child, h.child) orelse false;
        },
        else => return false,
    }
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn identEnd(text: []const u8, offset: u32) u32 {
    var i = offset;
    while (i < text.len and isIdentChar(text[i])) i += 1;
    return i;
}

/// Whether the cursor is in a comment, or inside a string or character literal (judged by the
/// token containing the character before the cursor)
fn commentOrString(r: *Resolver, file: FileId, offset: u32) resolve.Error!enum { none, comment, string } {
    if (offset == 0) return .none;
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const t = root.tokenAtOffset(offset - 1) orelse return .none;
    return switch (t.kind) {
        .line_comment, .doc_comment, .container_doc_comment => .comment,
        // A cursor after the closing quote is already outside the literal
        .string_literal, .char_literal => if (offset < t.offset + t.text.len) .string else .none,
        .identifier => if (std.mem.startsWith(u8, t.text, "@\"") and offset < t.offset + t.text.len) .string else .none,
        .multiline_string_literal_line => .string,
        // Unterminated string
        .invalid => if (t.text.len > 0 and (t.text[0] == '"' or t.text[0] == '\'' or std.mem.startsWith(u8, t.text, "@\""))) .string else .none,
        else => .none,
    };
}

/// Error names after `error.`: when the expected type is an error set (or error union), lists its
/// members; otherwise lists the error names that appear in this file (in error set definitions and
/// `error.X`, except the one at the cursor: an unfinished `error.` picks up the name on the next
/// line)
fn errorNames(r: *Resolver, out: *Collector, file: FileId, offset: u32, item: u32, e: Body.ExprId) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    if (try context.atSeeded(r, file, offset, true)) |a| if (a.literalExpected(e)) |want| {
        const set = switch (ip.key(want)) {
            .error_union_type => |eu| eu.err,
            else => want,
        };
        if (try queries.errorSetMembers(r, set)) |names| {
            for (names) |name| try out.add(.{ .label = name, .kind = .error_name });
            return;
        }
    };
    const tree = try r.itemTree(file);
    for (0..tree.items.len) |i| {
        const b = try r.body(file, @intCast(i));
        for (b.exprs, 0..) |x, xi| switch (x) {
            .error_set => |names| for (names) |name| try out.add(.{ .label = name, .kind = .error_name }),
            .error_value => |name| if (i != item or xi != @backingInt(e)) try out.add(.{ .label = name, .kind = .error_name }),
            else => {},
        };
    }
}

/// Position of the `@` when the cursor is in `@` or `@name` (excluding identifiers of the form
/// `@"..."`)
fn builtinStart(text: []const u8, offset: u32) ?u32 {
    var i = offset;
    while (i > 0 and isIdentChar(text[i - 1])) i -= 1;
    if (i == 0 or text[i - 1] != '@') return null;
    return i - 1;
}

/// Start of the string content when the cursor is in the string of `@import("` (the string may
/// be unterminated)
fn importString(text: []const u8, offset: u32) ?u32 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    const quote = std.mem.lastIndexOfScalar(u8, text[line_start..offset], '"') orelse return null;
    const start: u32 = @intCast(line_start + quote + 1);
    var head = std.mem.trimEnd(u8, text[line_start .. start - 1], " \t");
    if (!std.mem.endsWith(u8, head, "(")) return null;
    head = std.mem.trimEnd(u8, head[0 .. head.len - 1], " \t");
    if (!std.mem.endsWith(u8, head, "@import")) return null;
    return start;
}

/// Start of the label when the cursor is at the label position after `break :` / `continue :`
fn labelStart(text: []const u8, offset: u32) ?u32 {
    var i = offset;
    while (i > 0 and isIdentChar(text[i - 1])) i -= 1;
    const start = i;
    while (i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t')) i -= 1;
    if (i == 0 or text[i - 1] != ':') return null;
    i -= 1;
    while (i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t')) i -= 1;
    const end = i;
    while (i > 0 and isIdentChar(text[i - 1])) i -= 1;
    const word = text[i..end];
    if (!std.mem.eql(u8, word, "break") and !std.mem.eql(u8, word, "continue")) return null;
    return start;
}

/// Module names in `@import("...` (std, builtin, root, and the modules imported by each module
/// the file belongs to), and `.zig` / `.zon` files and subdirectories under the relative path.
/// Completion items are full paths from the start of the string.
fn importPaths(r: *Resolver, out: *Collector, file: FileId, typed: []const u8, range: Item.Range) resolve.Error!void {
    if (std.mem.lastIndexOfScalar(u8, typed, '/') == null) {
        for ([_][]const u8{ "std", "builtin", "root" }) |m| try out.add(.{ .label = m, .kind = .module, .replace = range });
        if (try r.ctx.get(ModuleGraph.Input, {})) |graph| {
            for (try graph.importNames(r.arena, file)) |name| try out.add(.{ .label = name, .kind = .module, .replace = range });
        }
    }
    try listPaths(r, out, file, typed, range, .import);
}

/// Inside a path string of `build.zig.zon` (the string holding the character before the cursor):
/// an element of `.paths` lists files and directories, and the `.path` of a dependency lists only
/// directories. Completion items are full paths from the start of the string
fn manifestPaths(r: *Resolver, out: *Collector, file: FileId, text: []const u8, offset: u32) resolve.Error!void {
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const tok = root.tokenAtOffset(offset - 1) orelse return;
    const kind = try manifest.pathKind(r, file, tok) orelse return;
    const start = tok.offset + 1;
    if (offset < start) return;
    try listPaths(r, out, file, text[start..offset], .{ .start = start, .end = offset }, switch (kind) {
        .included => .any,
        .dependency => .directories,
    });
}

const PathFilter = enum {
    /// `.zig` / `.zon` files and directories; directories end with `/`, so typing continues with a
    /// path inside them
    import,
    /// Any files and directories
    any,
    /// Directories only
    directories,
};

/// The entries of the directory named by the part of `typed` before its last `/`, relative to the
/// directory of `file` (excluding entries that start with `.` and `zig-out`). Completion items are
/// full paths from the start of the string
fn listPaths(r: *Resolver, out: *Collector, file: FileId, typed: []const u8, range: Item.Range, filter: PathFilter) resolve.Error!void {
    const vfs = r.ctx.db.env.vfs;
    const prefix = if (std.mem.lastIndexOfScalar(u8, typed, '/')) |s| typed[0 .. s + 1] else "";
    const base = std.fs.path.dirname(vfs.path(file)) orelse return;
    const dir_path = try std.fs.path.join(r.arena, &.{ base, prefix });
    var dir = std.Io.Dir.cwd().openDir(vfs.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(vfs.io);
    var it = dir.iterate();
    while (it.next(vfs.io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.' or std.mem.eql(u8, entry.name, "zig-out")) continue;
        switch (entry.kind) {
            .directory => {
                const slash = if (filter == .import) "/" else "";
                try out.add(.{ .label = try std.fmt.allocPrint(r.arena, "{s}{s}{s}", .{ prefix, entry.name, slash }), .kind = .folder, .replace = range });
            },
            .file => if (filter == .any or (filter == .import and
                (std.mem.endsWith(u8, entry.name, ".zig") or std.mem.endsWith(u8, entry.name, ".zon"))))
            {
                try out.add(.{ .label = try std.fmt.allocPrint(r.arena, "{s}{s}", .{ prefix, entry.name }), .kind = .file, .replace = range });
            },
            else => {},
        }
    }
}

/// The initializer that has the enum literal `e` as an element (without a field name)
fn initOf(b: *const Body, e: Body.ExprId) ?Body.ExprId {
    for (b.exprs, 0..) |x, i| switch (x) {
        .init => |init| for (init.fields) |f| if (f.name == null and f.value == e) return @fromBackingInt(@as(u32, @intCast(i))),
        else => {},
    };
    return null;
}

/// Fields of the initialized type (`T` for `?T`) that have not been assigned yet
fn initFields(r: *Resolver, out: *Collector, ty: Index, given: []const Body.FieldInit) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    const t = switch (ip.key(ty)) {
        .optional_type => |c| c,
        else => ty,
    };
    switch (ip.key(t)) {
        .container_type => |c| if (c.kind != .@"struct" and c.kind != .@"union") return,
        else => return,
    }
    const ns = try queries.namespaceOfType(r, t) orelse return;
    const tree = try r.itemTree(ns.file);
    outer: for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        if (it.kind != .field) continue;
        const name = it.name orelse continue;
        for (given) |g| if (g.name) |n| if (std.mem.eql(u8, n, name)) continue :outer;
        const fty = (try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = ns.file, .item = it.ast_id }, .inst = queries.instOfType(ip, t) })).ty;
        try out.add(.{ .label = name, .kind = .field, .doc = it.doc, .detail = if (fty != .unknown) try render.typeAlloc(r, fty) else null });
    }
}

/// Members after `ns.`; non-pub declarations are accessible within the same file
fn members(r: *Resolver, out: *Collector, ns: Namespace, same_file: bool) resolve.Error!void {
    const tree = try r.itemTree(ns.file);
    if (ns.container >= tree.containers.len) return;
    try decls(r, out, ns.file, tree, ns.container, same_file, 0);
    const kind = tree.containers[ns.container].kind;
    // Enum members in the same file (those of other files come from `decls`); accessing a field
    // on the type of a tagged union yields the tag of the field (`Value.null_val`), which can
    // be coerced to the union
    const fields = (same_file and kind == .@"enum") or
        (kind == .@"union" and try eval.unionTag(r, try queries.containerType(r, ns, null)) != null);
    if (!fields) return;
    for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        if (it.kind == .field) if (it.name) |name| try out.add(.{ .label = name, .kind = .enum_member, .doc = it.doc });
    }
}
