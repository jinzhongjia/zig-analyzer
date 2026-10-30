//! Completion: after `a.`, lists the members of the namespace; after `.`, lists members by the
//! expected type, and in initializers the fields not yet assigned; after `.@`, the same names
//! quoted (`.@"name"`); after `error.`, lists error names; after `@`, lists builtins (not in `.zon`
//! files); inside `@import("`, lists modules and files; after `break :` /
//! `continue :`, lists labels; otherwise lists the names visible at the cursor (local names and
//! the declarations of enclosing containers). When `build.zig.zon` has no result type, its fields
//! and paths are listed by the built-in schema (see `manifest.zig`).
//! No completion in comments and strings (other than `@import("` and the paths of `build.zig.zon`).
//! With snippets, functions and builtins complete as calls (see `addCallSnippets`), and common
//! snippets are also offered where a statement or a declaration starts (see `addKeywordSnippets`).

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
const tree_mod = @import("../syntax/tree.zig");
const SyntaxNode = tree_mod.SyntaxNode;
const SyntaxToken = tree_mod.SyntaxToken;
const ast = @import("../syntax/ast.zig");
const isTrivia = @import("../syntax/kind.zig").isTrivia;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;
const fuzzy = @import("../ide_db/fuzzy.zig");
const value = @import("../sema/value.zig");
const engine = @import("../db/engine.zig");
const mem = @import("../util/mem.zig");

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
    /// Use snippets (the client supports them and they are enabled): functions complete as calls,
    /// and common snippets are offered where a statement or a declaration starts
    snippets: bool = false,
    /// Call snippets insert a placeholder for each argument; otherwise only the parentheses
    argument_placeholders: bool = true,
    /// Complete only paths (`@import` strings and the paths of `build.zig.zon`), with no items
    /// elsewhere: completion triggered by `/` or `"`, which outside such a string are a division,
    /// a comment, or the quotes of another string
    paths_only: bool = false,
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
    /// Range to replace (byte offsets in the file; the inserted text is `label`, or `snippet` when
    /// there is one); when null, the client determines it by word. It ends at the end of the word
    /// (for paths, of the string content) after the cursor; inserting instead of replacing ends at
    /// the cursor. Needed for characters that are not part of a word, such as `@` and the `/` in
    /// paths.
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
    /// item is selected (see `describe`): for auto-import candidates and functions (for an alias of
    /// a function, the function it refers to)
    target: ?imports.Target = null,
    /// The value the candidate refers to in name completion, whose type is computed when ranking
    /// by the expected type (see `Expected`)
    origin: Origin = .none,
    /// LSP snippet inserted instead of `label`; `replace` is not null when there is one
    snippet: ?[]const u8 = null,
    /// A function called through a value (a member path of a local value): a call skips the
    /// receiver
    bound: bool = false,

    pub const Origin = union(enum) {
        none,
        /// The type is known: local names and member paths of local values
        value: TypedValue,
        /// A declaration or a file (declarations in scope, auto-import candidates): the type is
        /// computed only when needed
        target: imports.Target,
    };

    pub const Kind = enum { param, type_param, constant, variable, function, method, namespace, @"struct", @"enum", type, field, enum_member, error_name, builtin, module, file, folder, label, snippet };
    pub const Range = struct { start: u32, end: u32 };
};

pub fn complete(r: *Resolver, file: FileId, offset: u32, options: Options) resolve.Error!Result {
    var owner: imports.Owner = .unknown;
    const visible = try completeVisible(r, file, offset, &owner, options.paths_only);
    if (options.paths_only and visible.context != .path) return .{ .items = &.{} };
    const base = visible.items;
    // Auto-import and snippets only in Zig source files: inserting an import declaration or code
    // into a `.zon` or similar file would break it
    if (!imports.isZigSource(r.ctx.db.env.vfs.path(file))) return .{ .items = base };
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    if (offset > text.len) return .{ .items = base };
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const name = if (offset == 0) null else try importPrefix(r.arena, root, text, offset);
    if (name == null and !options.snippets) return .{ .items = base };
    var items: std.ArrayList(Item) = .empty;
    try items.appendSlice(r.arena, base);
    var result: Result = .{ .items = &.{}, .import_position = name != null and (options.auto_import or options.detect_import_position) };
    if (name) |n| {
        const limit = options.max_auto_imports;
        const paths = try localMembers(r, file, visible.roots, n, limit);
        var extra: std.ArrayList(Item) = .empty;
        try extra.appendSlice(r.arena, paths.items);
        result.is_incomplete = paths.incomplete;
        if (options.auto_import) {
            const found = try imports.complete(r, file, offset, owner, n.prefix, limit, options.imports);
            result.is_incomplete = result.is_incomplete or found.is_incomplete;
            for (found.items) |candidate| {
                // The core (`imports.complete`) has already rendered the path segment by segment;
                // the whole qualified expression must not be escaped as an identifier again.
                const filter = try completionFilter(r.arena, n, candidate.filter);
                var duplicate = false;
                for (items.items[0..base.len]) |*visible_item| if (std.mem.eql(u8, visible_item.label, candidate.label)) {
                    // Only visible bindings are merged; auto-import items with the same name from
                    // different sources must remain separate choices.
                    if (candidate.import_edit == null) {
                        visible_item.replace = n.range;
                        visible_item.filter = filter;
                        visible_item.qualifier = candidate.qualifier;
                        visible_item.target = candidate.target;
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
                    .replace = n.range,
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
    }
    if (options.snippets) {
        const pos: ?Position = switch (visible.context) {
            .none, .scope => try positionOf(r.arena, root, text, offset),
            else => null,
        };
        try addCallSnippets(r, file, text, root, offset, visible, pos, items.items, options.argument_placeholders);
        if (pos) |p| try addKeywordSnippets(r, file, text, offset, visible, p, &items);
    }
    if (name) |n| try rank(r.arena, items.items, n.prefix, try expectedAt(r, file, offset, visible.at));
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
        if (expected) |x| if (it.score > 0 and try x.matches(it.origin, it.snippet != null)) {
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

/// The completion items at the cursor and the context of the cursor
const Visible = struct {
    items: []const Item = &.{},
    context: Context = .none,
    /// `.member`: the left-hand side is a value (not a type or namespace), which is the first
    /// argument when a function in it is called
    bound: bool = false,
    /// `.scope`: the member and the scope at the cursor
    item: u32 = 0,
    scope: Body.ScopeId = .root,
    /// Inference result of the member at the cursor (when computed)
    at: ?context.At = null,
    /// `.scope`: the local values that are roots of member paths, from the innermost outward
    roots: []const Root = &.{},

    const Context = enum {
        /// Not in any member
        none,
        /// In a comment or string, or past the end of the text
        ignored,
        builtin,
        /// In the string of an `@import` or a string of `build.zig.zon` (paths)
        path,
        label,
        /// After `lhs.`
        member,
        error_name,
        /// After `.` (enum literals, decl literals)
        enum_literal,
        /// Field name in an initializer
        init_field,
        /// Names in scope
        scope,
    };
};

/// `cursor_owner` records the member found at the cursor, which auto-import reuses; with
/// `paths_only`, nothing but paths is completed
fn completeVisible(r: *Resolver, file: FileId, offset: u32, cursor_owner: *imports.Owner, paths_only: bool) resolve.Error!Visible {
    var out: Collector = .{ .arena = r.arena };
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    if (offset > text.len) return .{ .context = .ignored };

    const literal = try commentOrString(r, file, offset);
    if (literal == .comment) return .{ .context = .ignored };
    // The following contexts are mostly error nodes in the syntax tree (such as a lone `@` or an
    // unterminated string), so they are recognized directly from the source text
    if (literal == .none and !paths_only) if (builtinStart(text, offset)) |start| {
        // Only a name follows a `.`, so `.@` starts a quoted name (`.@"name"`): the names that
        // complete after the `.`, quoted
        if (afterDot(text, start)) return quotedAfterDot(r, file, start, offset, cursor_owner);
        // `.zon` files have no builtin calls
        if (std.mem.endsWith(u8, r.ctx.db.env.vfs.path(file), ".zon")) return .{ .context = .ignored };
        const range: Item.Range = .{ .start = start, .end = identEnd(text, offset) };
        for (builtins.entries) |entry| try out.add(.{ .label = entry.name, .kind = .builtin, .replace = range, .detail = entry.signature, .doc = entry.documentation });
        return .{ .items = out.items.items, .context = .builtin };
    };
    if (importString(text, offset)) |start| {
        try importPaths(r, &out, file, text[start..offset], .{ .start = start, .end = stringContentEnd(text, offset) });
        return .{ .items = out.items.items, .context = .path };
    }
    if (literal == .string) {
        try manifestPaths(r, &out, file, text, offset);
        return .{ .items = out.items.items, .context = .path };
    }
    if (paths_only) return .{ .context = .ignored };

    cursor_owner.* = .{ .known = try r.ownerAt(file, offset, true) };
    const item = cursor_owner.known orelse return .{};
    const node = try r.itemNode(file, item) orelse return .{};
    const b = try r.body(file, item);
    const rel = offset - node.offset;

    if (labelStart(text, offset) != null) {
        var s: ?Body.ScopeId = b.scopeAt(rel);
        while (s) |id| : (s = b.scope(id).parent) if (b.scope(id).label) |l| try out.add(.{ .label = l.name, .kind = .label });
        return .{ .items = out.items.items, .context = .label };
    }

    // `lhs.` / `lhs.na`: the character before the cursor is inside a field access, and not
    // inside the left-hand expression
    if (rel > 0) if (b.exprAt(rel - 1)) |e| switch (b.expr(e)) {
        .field_access => |fa| if (rel - 1 >= b.range(fa.lhs).end) {
            out.member_mode = true;
            if (try r.evalNamespace(file, item, b, fa.lhs)) |ns| {
                try members(r, &out, ns, ns.file == file);
                return .{ .items = out.items.items, .context = .member };
            }
            // Via the type: fields and methods of the instance (inside the body of a generic
            // function, use the instance from a call site)
            const a = try context.atSeeded(r, file, offset, true) orelse return .{ .context = .member };
            const tv = a.exprType(fa.lhs);
            // Methods receiving `*T` need a value that can be modified (see `receives`)
            const mutable = !tv.isType() and !try infer.placeIsConst(r, a.file, a.item, a.body, a, fa.lhs);
            try typedMembers(r, &out, tv, mutable, file);
            return .{ .items = out.items.items, .context = .member, .bound = !tv.isType(), .at = a };
        },
        else => {},
    };

    if (rel > 0) if (b.exprAt(rel - 1)) |e| if (b.expr(e) == .error_value) {
        out.member_mode = true;
        try errorNames(r, &out, file, offset, item, e);
        return .{ .items = out.items.items, .context = .error_name };
    };

    // `.` / `.na` (enum literals, decl literals): list members by the expected type; in an
    // initializer of a struct or union (`.{ .x = 1, .| }`), list the fields not yet assigned. An
    // element of an array, slice or tuple initializer is a value whose expected type is the element
    // type
    if (rel > 0) if (b.exprAt(rel - 1)) |e| if (b.expr(e) == .enum_literal) {
        out.member_mode = true;
        const a = try context.atSeeded(r, file, offset, true) orelse return .{ .context = .enum_literal };
        if (initOf(b, e)) |init| {
            const x = b.expr(init).init;
            const ty = if (x.ty == null) a.literalExpected(init) orelse {
                for (try manifest.fieldCompletions(r, file, b, init)) |f| try out.add(.{ .label = f.name, .kind = .field, .doc = f.doc });
                return .{ .items = out.items.items, .context = .init_field };
            } else a.exprType(init).ty;
            if (fieldsType(r.ctx.db.env.ip, ty)) |t| {
                try initFields(r, &out, t, x.fields);
                return .{ .items = out.items.items, .context = .init_field };
            }
        }
        const mode: DeclLiterals = if (a.literalTagsOnly(e)) .none else if (tryOperand(b, e)) .@"try" else .value;
        try expectedMembers(r, &out, a.literalExpected(e) orelse return .{ .context = .enum_literal, .at = a }, mode, file);
        return .{ .items = out.items.items, .context = .enum_literal, .at = a };
    };

    // Names in scope: when the cursor immediately follows a name, use the scope of that name
    const scope = if (rel > 0) if (b.exprAt(rel - 1)) |e| switch (b.expr(e)) {
        .name_ref => b.expr_scopes[@backingInt(e)],
        else => b.scopeAt(rel),
    } else b.scopeAt(rel) else b.scopeAt(rel);
    // The kinds of local names come from the inference result of the member at the cursor
    // (inside a generic function body, from a call-site instance)
    const at = try context.atSeeded(r, file, offset, true);
    const types: BindingTypes = if (at) |a| .{ .at = a } else .none;
    // Local values that are not shadowed are the roots of member paths
    var roots: std.ArrayList(Root) = .empty;
    try locals(r, &out, b, scope, null, types, &roots);

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
        try locals(r, &out, pb, pb.scopeAt(c_node.offset - owner.offset), weight, .{ .res = parent_res }, &roots);
        container = tree.items[parent].container;
    }
    return .{ .items = out.items.items, .context = .scope, .item = item, .scope = scope, .at = at, .roots = roots.items };
}

/// Completion at `.@` (the `@` at `at`): the names that complete right after the `.` (members,
/// enum and decl literals, initializer fields), written as quoted identifiers that replace from
/// the `@`. Nothing when name characters precede the cursor (`.@na` is no name)
fn quotedAfterDot(r: *Resolver, file: FileId, at: u32, offset: u32, cursor_owner: *imports.Owner) resolve.Error!Visible {
    if (offset != at + 1) return .{ .context = .ignored };
    var visible = try completeVisible(r, file, at, cursor_owner, false);
    switch (visible.context) {
        .member, .enum_literal, .init_field => {},
        else => return .{ .context = .ignored },
    }
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    const range: Item.Range = .{ .start = at, .end = identEnd(text, offset) };
    const items = try r.arena.dupe(Item, visible.items);
    for (items) |*it| {
        if (!std.mem.startsWith(u8, it.label, "@\"")) it.label = try std.fmt.allocPrint(r.arena, "@\"{s}\"", .{it.label});
        it.replace = range;
    }
    visible.items = items;
    return visible;
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
fn locals(r: *Resolver, out: *Collector, b: *const Body, from: Body.ScopeId, weight: ?f32, types: BindingTypes, roots: *std.ArrayList(Root)) resolve.Error!void {
    var s: ?Body.ScopeId = from;
    while (s) |id| : (s = b.scope(id).parent) {
        for (b.scope(id).bindings) |bid| {
            const binding = b.binding(bid);
            const tv = types.of(bid);
            if (!out.seen.contains(binding.name)) if (rootOf(binding, tv, weight != null)) |root| try roots.append(out.arena, root);
            const kind = kindOf(symbol_kind.ofBinding(r.ctx.db.env.ip, binding, tv));
            try out.add(.{
                .label = binding.name,
                .kind = kind,
                .weight = weight orelse if (binding.kind == .param) param_weight else local_weight,
                .target = if (kind == .function) try fnTarget(r, tv) else null,
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
        const target: ?imports.Target = switch (it.kind) {
            .@"fn" => .{ .decl = .{ .file = file, .item = m } },
            // An alias of a function: the function it refers to (the type of the declaration has
            // already been computed for the kind)
            .@"const" => if (kind == .function) try fnTarget(r, try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = file, .item = it.ast_id } })) else null,
            else => null,
        };
        try out.add(.{ .label = name, .kind = kind, .doc = it.doc, .target = target, .weight = weight, .origin = .{ .target = .{ .decl = .{ .file = file, .item = m } } } });
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

/// Lists members by type: declarations when the value is a type; for other values (also through a
/// single pointer), their members (see `valueMembers`): the fields, and the functions that can be
/// called on the value as methods (see `receives`; `mutable` tells whether the value can be
/// modified)
fn typedMembers(r: *Resolver, out: *Collector, tv: TypedValue, mutable: bool, from: FileId) resolve.Error!void {
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
    // A single pointer is dereferenced automatically once: len of `*[N]T`, fields and methods of
    // `*S`, len and ptr of `*[]T`; whether the value can be modified then depends on the pointer
    const holder = (Place{ .ty = tv.ty, .mutable = mutable }).deref(ip);
    for (try valueMembers(r, from, holder.ty)) |m| switch (m.what) {
        .typed => |ty| try out.add(.{ .label = m.name, .kind = .field, .detail = if (ty != .unknown) try render.typeAlloc(r, ty) else null }),
        .field => |f| {
            const ty = (try declType(r, f)).ty;
            try out.add(.{ .label = m.name, .kind = .field, .doc = m.doc, .detail = if (ty != .unknown) try render.typeAlloc(r, ty) else null });
        },
        .method => |f| {
            const ftv = try declType(r, f);
            if (!callableOn(ip, ftv.ty, f.alias, holder)) continue;
            // Function aliases (`pub const isPowerPC = isPowerpc;`) show the signature of the
            // function they refer to when selected
            try out.add(if (f.alias)
                .{ .label = m.name, .kind = .function, .doc = m.doc, .target = try fnTarget(r, ftv) }
            else
                .{ .label = m.name, .kind = kindOf(try symbol_kind.ofDecl(r, f.file, f.item)), .doc = m.doc, .target = .{ .decl = .{ .file = f.file, .item = f.item } } });
        },
    };
}

/// Which declarations of the expected type `expectedMembers` lists
const DeclLiterals = enum {
    /// None: the expected type comes from peer type resolution, which names only tags
    none,
    /// Declarations that can serve as decl literals (see `producesType`)
    value,
    /// The operand of `try` (`try .|`, `try .f|()`): only functions returning an error union whose
    /// payload is the type (see `producesType`); tags are not error unions
    @"try",
};

/// After `.`: enum members and union fields of the expected type (`T` for `?T`), and the
/// declarations selected by `decl_literals`
fn expectedMembers(r: *Resolver, out: *Collector, ty: Index, decl_literals: DeclLiterals, from: FileId) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    // Matching the compiler, strip error unions and optionals from the result type
    // (`fn f() !Color { return .red; }`)
    var t = ty;
    while (true) t = switch (ip.key(t)) {
        .error_union_type => |eu| eu.payload,
        .optional_type => |c| c,
        else => break,
    };
    const tags = decl_literals != .@"try";
    switch (ip.key(t)) {
        .reified_type, .union_tag_type => {
            if (tags) for (try eval.enumMemberNames(r, t)) |name| try out.add(.{ .label = name, .kind = .enum_member });
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
            .field => if (tags) switch (kind) {
                .@"enum" => try out.add(.{ .label = name, .kind = .enum_member, .doc = it.doc }),
                .@"union" => try out.add(.{ .label = name, .kind = .field, .doc = it.doc }),
                else => {},
            },
            .@"const", .@"fn" => {
                if (decl_literals == .none or (ns.file != from and !it.flags.is_pub)) continue;
                const decl_ty = (try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = ns.file, .item = it.ast_id }, .inst = inst })).ty;
                if (!producesType(ip, decl_ty, t, it.kind == .@"fn", decl_literals == .@"try")) continue;
                const is_fn = it.kind == .@"fn";
                try out.add(.{ .label = name, .kind = kindOf(try symbol_kind.ofDecl(r, ns.file, m)), .doc = it.doc, .target = if (is_fn) .{ .decl = .{ .file = ns.file, .item = m } } else null });
            },
            else => {},
        }
    }
}

/// Whether a declaration can serve as a decl literal of type `t`: a constant of type `t`, or a
/// function returning `t` or `!t`; for the operand of `try` (`in_try`), only a function returning
/// `!t`. An unknown type counts as yes
fn producesType(ip: *InternPool, decl_ty: Index, t: Index, is_fn: bool, in_try: bool) bool {
    if (!is_fn) return !in_try and (decl_ty == .unknown or decl_ty == t);
    if (decl_ty == .unknown) return true;
    const ret = switch (ip.key(decl_ty)) {
        .fn_type => |f| f.ret,
        else => return false,
    };
    if (ret == .unknown or (!in_try and ret == t)) return true;
    return switch (ip.key(ret)) {
        .error_union_type => |eu| eu.payload == t or eu.payload == .unknown,
        else => false,
    };
}

/// The enum literal `e` is the operand of `try`, directly (`try .f`) or as the callee of the call
/// that is (`try .f()`)
fn tryOperand(b: *const Body, e: Body.ExprId) bool {
    var operand = e;
    for (b.exprs, 0..) |x, i| switch (x) {
        .call => |c| if (c.callee == e) {
            operand = @fromBackingInt(@as(u32, @intCast(i)));
            break;
        },
        else => {},
    };
    for (b.exprs) |x| switch (x) {
        .prefix => |p| if (p.op == .keyword_try and p.operand == operand) return true,
        else => {},
    };
    return false;
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

/// Members of a value (dereferenced): fields, and the functions and consts in `from` or pub
/// (whether a const is a function is known only when it is used). Enum and opaque values have no
/// fields: enum members are accessed through the type. Values that are not containers, tuples,
/// slices, or arrays have no members (`?T`, `E!T`, single-item pointers to pointers, many-item
/// pointers, and so on)
fn valueMembers(r: *Resolver, from: FileId, t: Index) resolve.Error![]const Member {
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
                    .@"fn", .@"const" => if (ns.file == from or it.flags.is_pub) try out.append(r.arena, .{ .name = name, .doc = it.doc, .what = .{ .method = decl } }),
                    else => {},
                }
            }
        },
        else => {},
    }
    return out.items;
}

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

    /// Members of a value (see `valueMembers`)
    fn membersOf(s: *MemberSearch, t: Index) resolve.Error![]const Member {
        if (s.members.get(t)) |known| return known;
        const found = try valueMembers(s.r, s.file, t);
        try s.members.put(s.r.arena, t, found);
        return found;
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
                if (!callableOn(ip, tv.ty, f.alias, p.holder)) return null;
                // Classified like the same declaration after `.` (a function in a file is Function)
                item.kind = kindOf(try symbol_kind.ofDecl(r, f.file, f.item));
                item.bound = true;
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

/// Whether the function or function alias of type `ty` can be called as a method on the value at
/// `holder` (see `receives`): a function whose signature cannot be computed counts as yes, an alias
/// only when its value is known to be a function
fn callableOn(ip: *InternPool, ty: Index, alias: bool, holder: Place) bool {
    return switch (ip.key(ty)) {
        .fn_type => |sig| sig.params.len != 0 and receives(ip, sig.params[0], holder),
        else => !alias and ty == .unknown,
    };
}

/// Whether the first parameter of a method can receive the value at `holder` (matches the
/// compiler): the parameter is the enclosing container `T`, `?T`, `E!T`, or a single-item or C
/// pointer to it (also `?*T`), and a pointer that is not const needs a value that can be modified;
/// an `anytype` parameter, whose type is not known before a call, and a parameter whose type cannot
/// be computed count as yes
fn receives(ip: *InternPool, param: Index, holder: Place) bool {
    if (param == .unknown or sameContainer(ip, param, holder.ty)) return true;
    return switch (ip.key(param)) {
        .ptr_type => |p| (p.size == .one or p.size == .c) and sameContainer(ip, p.child, holder.ty) and (p.is_const or holder.mutable),
        .optional_type => |c| sameContainer(ip, c, holder.ty) or (ip.key(c) == .ptr_type and receives(ip, c, holder)),
        .error_union_type => |eu| sameContainer(ip, eu.payload, holder.ty),
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

    /// Whether the type of the candidate fits the expected type (see `fits`; `called`: the
    /// candidate is inserted as a call); the types of declarations and files are computed only here
    fn matches(x: Expected, origin: Item.Origin, called: bool) resolve.Error!bool {
        const tv: TypedValue = switch (origin) {
            .none => return false,
            .value => |tv| tv,
            .target => |t| switch (t) {
                .decl => |d| try queries.defType(x.r, .{ .item = .{ .file = d.file, .item = d.item } }, null, x.inst),
                .file => |f| try queries.importValue(x.r, f),
            },
        };
        return fits(x.r.ctx.db.env.ip, x.ty, tv.ty, called);
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
                const it = (try r.itemTree(a.file)).items[a.item];
                if (it.kind != .@"fn") return null;
                const ret = a.exprType(b.type_expr orelse return null).asType() orelse return null;
                // `!T`: `T` with the error set inferred from the body (see `queries.returnType`)
                if (!it.flags.inferred_error_set or ret == .unknown) return ret;
                const set = try a.ip.get(.{ .inferred_error_set = .{ .file = a.file, .decl = it.ast_id, .inst = if (a.seeded) |s| s.inst else null } });
                return try a.ip.get(.{ .error_union_type = .{ .err = set, .payload = ret } });
            },
            .assign => |s| if (s.rhs == e) return if (s.op == .equal) a.exprType(s.lhs).ty else null,
            .binary => |s| {
                if (isComparison(s.op) and (s.lhs == e or s.rhs == e)) {
                    return comparedType(r, a.exprType(if (s.lhs == e) s.rhs else s.lhs).ty, s.op);
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
/// compared with its tag (`u == .none`), and an error union only with an error set (`eu ==
/// error.X`, by `==` and `!=`); comptime numbers, enum literals, null, and undefined have no
/// definite type, and types whose values cannot be compared (see `comparable`) have none either
fn comparedType(r: *Resolver, t: Index, op: SyntaxKind) resolve.Error!?Index {
    switch (t) {
        .unknown, .comptime_int_type, .comptime_float_type, .enum_literal_type, .null_type, .undefined_type => return null,
        else => {},
    }
    const ip = r.ctx.db.env.ip;
    switch (ip.key(t)) {
        .container_type => |c| if (c.kind == .@"union") return eval.unionTag(r, t),
        .reified_type => |rt| if (rt.kind == .@"union") return eval.unionTag(r, t),
        .error_union_type => |eu| return if (op == .equal_equal or op == .bang_equal) eu.err else null,
        else => {},
    }
    return if (comparable(ip, t)) t else null;
}

/// Whether values of type `t` can be compared with each other: not slices, arrays, and tuples (or
/// optionals of them), as in the compiler
fn comparable(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .ptr_type => |p| p.size != .slice,
        .array_type, .abstract_array_type, .tuple_type, .anon_struct_type => false,
        .optional_type => |child| comparable(ip, child),
        else => true,
    };
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
/// `*const T` and `[]T` as `[]const T`; functions whose return value fits, and function pointers
/// whose return value fits when the candidate is inserted as a call (`called`; a function pointer
/// never coerces to what it returns). Other conversions (integer widening, comptime_int, and so on)
/// do not count
fn fits(ip: *InternPool, want: Index, have: Index, called: bool) bool {
    if (coerces(ip, want, have)) return true;
    const f = switch (ip.key(have)) {
        .fn_type => |f| f,
        .ptr_type => |p| if (called and p.size == .one) switch (ip.key(p.child)) {
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
        .error_union_type => |eu| {
            if (coerces(ip, eu.payload, have)) return true;
            // An error set that fits in `E`, and `E'!T` whose error set fits in `E`
            if (isErrorSet(ip, have)) return errorSetFits(ip, eu.err, have);
            const h = switch (ip.key(have)) {
                .error_union_type => |h| h,
                else => return false,
            };
            return errorSetFits(ip, eu.err, h.err) and (value.eqlTypes(ip, eu.payload, h.payload) orelse false);
        },
        .ptr_type => |w| {
            const h = switch (ip.key(have)) {
                .ptr_type => |h| h,
                // A function as a pointer to it
                .fn_type => return w.size == .one and (value.eqlTypes(ip, w.child, have) orelse false),
                else => return false,
            };
            if (h.size == .one and (w.size == .slice or w.size == .many)) {
                // A pointer to an array as a slice or a many-item pointer (`*const [5:0]u8` as
                // `[]const u8`)
                const array = switch (ip.key(h.child)) {
                    .array_type => |array| array,
                    else => return false,
                };
                if (h.is_const and !w.is_const) return false;
                if (w.sentinel) |s| if (array.sentinel != s) return false;
                return value.eqlTypes(ip, w.child, array.child) orelse false;
            }
            if (w.size != h.size or (w.size != .one and w.size != .slice)) return false;
            if (!w.is_const or h.is_const or !std.meta.eql(w.sentinel, h.sentinel)) return false;
            return value.eqlTypes(ip, w.child, h.child) orelse false;
        },
        else => return false,
    }
}

fn isErrorSet(ip: *InternPool, t: Index) bool {
    return t == .anyerror_type or switch (ip.key(t)) {
        .error_set_type, .inferred_error_set => true,
        else => false,
    };
}

/// Whether every error of the error set `have` is in the error set `want`: always for `anyerror`
/// and for an inferred error set (the one of the function being written, which takes in the
/// errors returned to it); for a written set, when `have` is a written set with no other names
fn errorSetFits(ip: *InternPool, want: Index, have: Index) bool {
    if (want == .anyerror_type) return isErrorSet(ip, have);
    switch (ip.key(want)) {
        .inferred_error_set => return isErrorSet(ip, have),
        .error_set_type => |names| {
            const own = switch (ip.key(have)) {
                .error_set_type => |own| own,
                else => return false,
            };
            for (own) |name| {
                for (names) |n| {
                    if (std.mem.eql(u8, n, name)) break;
                } else return false;
            }
            return true;
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

/// The last token before `offset`, skipping whitespace, is a single `.` (not `..` or `...`, after
/// which an expression follows)
fn afterDot(text: []const u8, offset: u32) bool {
    var i = offset;
    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) i -= 1;
    return i > 0 and text[i - 1] == '.' and (i == 1 or text[i - 2] != '.');
}

/// Start of the string content when the cursor is in the string of `@import("` (the string may
/// be unterminated; escaped quotes do not end it)
fn importString(text: []const u8, offset: u32) ?u32 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    var open: ?usize = null;
    var i = line_start;
    while (i < offset) : (i += 1) switch (text[i]) {
        '"' => open = if (open == null) i + 1 else null,
        '\\' => if (open != null) {
            i += 1;
        },
        else => {},
    };
    const start: u32 = @intCast(open orelse return null);
    var head = std.mem.trimEnd(u8, text[line_start .. start - 1], " \t");
    if (!std.mem.endsWith(u8, head, "(")) return null;
    head = std.mem.trimEnd(u8, head[0 .. head.len - 1], " \t");
    if (!std.mem.endsWith(u8, head, "@import")) return null;
    return start;
}

/// End of the content of the string literal holding `offset`: its closing quote, or `offset` when
/// the string is not closed in the line
fn stringContentEnd(text: []const u8, offset: u32) u32 {
    var i = offset;
    while (i < text.len and text[i] != '\n') : (i += 1) switch (text[i]) {
        '"' => return i,
        '\\' => i += 1,
        else => {},
    };
    return offset;
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
    try listPaths(r, out, file, text[start..offset], .{ .start = start, .end = stringContentEnd(text, offset) }, switch (kind) {
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

/// The entries of the directory named by the part of `typed` (the string content as written, with
/// escapes) before its last `/`, relative to the directory of `file` (excluding entries that start
/// with `.`, the build output `zig-out`, and the fetched packages `zig-pkg`). Completion items are
/// full paths from the start of the string: the directory as written, followed by the entry name
/// escaped for a string literal
fn listPaths(r: *Resolver, out: *Collector, file: FileId, typed: []const u8, range: Item.Range, filter: PathFilter) resolve.Error!void {
    const vfs = r.ctx.db.env.vfs;
    const prefix = if (std.mem.lastIndexOfScalar(u8, typed, '/')) |s| typed[0 .. s + 1] else "";
    const quoted = try std.fmt.allocPrint(r.arena, "\"{s}\"", .{prefix});
    const dir_name = std.zig.string_literal.parseAlloc(r.arena, quoted) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLiteral => return,
    };
    const base = std.fs.path.dirname(vfs.path(file)) orelse return;
    const dir_path = try std.fs.path.join(r.arena, &.{ base, dir_name });
    var dir = std.Io.Dir.cwd().openDir(vfs.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(vfs.io);
    var it = dir.iterate();
    while (it.next(vfs.io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.' or std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, "zig-pkg")) continue;
        switch (entry.kind) {
            .directory => {
                const slash = if (filter == .import) "/" else "";
                try out.add(.{ .label = try std.fmt.allocPrint(r.arena, "{s}{f}{s}", .{ prefix, std.zig.fmtString(entry.name), slash }), .kind = .folder, .replace = range });
            },
            .file => if (filter == .any or (filter == .import and
                (std.mem.endsWith(u8, entry.name, ".zig") or std.mem.endsWith(u8, entry.name, ".zon"))))
            {
                try out.add(.{ .label = try std.fmt.allocPrint(r.arena, "{s}{f}", .{ prefix, std.zig.fmtString(entry.name) }), .kind = .file, .replace = range });
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

/// The type whose fields an initializer of type `ty` names (`T` for `?T`): a struct or union;
/// null for the other types, whose initializers list elements (arrays, slices, tuples)
fn fieldsType(ip: *InternPool, ty: Index) ?Index {
    const t = switch (ip.key(ty)) {
        .optional_type => |c| c,
        else => ty,
    };
    return switch (ip.key(t)) {
        .container_type => |c| if (c.kind.isStruct() or c.kind == .@"union") t else null,
        else => null,
    };
}

/// Fields of the struct or union `t` (see `fieldsType`) that have not been assigned yet
fn initFields(r: *Resolver, out: *Collector, t: Index, given: []const Body.FieldInit) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
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

// ── snippet ──────────────────────────────────────────────────────────

/// Source weight of snippets (see `rank`): below names in scope and auto-import candidates
/// accessed through an existing namespace (`imports.visible_weight`), above candidates that need a
/// new import (`imports.import_weight`)
const snippet_weight = 0.8;

/// Syntactic position of the word at the cursor
const Position = struct {
    /// Range of the word: the identifier characters before and after the cursor
    start: u32,
    end: u32,
    /// The last token before the word (skipping comments)
    prev: ?SyntaxToken,
    /// The word immediately follows `pub`
    after_pub: bool = false,
    /// A doc comment precedes the word (or the `pub` it follows)
    doc: bool = false,
    kind: Kind = .other,
    /// For `.statement`, the enclosing block; for `.member`, the enclosing container
    /// (`container_decl` or the file)
    node: ?SyntaxNode = null,

    const Kind = enum {
        /// Start of a statement in a block
        statement,
        /// Start of a container member
        member,
        other,
    };
};

fn positionOf(arena: Allocator, root: SyntaxNode, text: []const u8, offset: u32) Allocator.Error!Position {
    var start = offset;
    while (start > 0 and isIdentChar(text[start - 1])) start -= 1;
    var pos: Position = .{ .start = start, .end = identEnd(text, offset), .prev = tokenBefore(root, start) };
    // The word starts inside a token (the digits after the `.` of `1.5`, the cursor between the
    // two characters of `=>`): neither a statement nor a member starts there
    if (pos.prev) |p| if (p.range().end > start) return pos;
    var before = pos.prev;
    var gap_end = start;
    if (before) |p| if (p.kind == .keyword_pub) {
        pos.after_pub = true;
        gap_end = p.offset;
        before = tokenBefore(root, p.offset);
    };
    const gap_start = if (before) |p| p.range().end else 0;
    pos.doc = hasDocComment(text[gap_start..gap_end]);
    const node = try scopeAfter(arena, root, before) orelse return pos;
    pos.node = node;
    pos.kind = switch (node.kind()) {
        .block => .statement,
        .source_file, .container_decl => .member,
        else => .other,
    };
    return pos;
}

/// The last token before `offset`, skipping whitespace and comments (including doc comments)
fn tokenBefore(root: SyntaxNode, offset: u32) ?SyntaxToken {
    var at = offset;
    while (at > 0) {
        const t = root.tokenAtOffset(at - 1) orelse return null;
        switch (t.kind) {
            .doc_comment, .container_doc_comment => {},
            else => if (!isTrivia(t.kind)) return t,
        }
        at = t.offset;
    }
    return null;
}

/// The text contains a `///` doc comment (`////` is a normal comment)
fn hasDocComment(gap: []const u8) bool {
    var lines = std.mem.splitScalar(u8, gap, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "///") and !std.mem.startsWith(u8, t, "////")) return true;
    }
    return false;
}

/// The block or container of a statement or member that starts after `prev`: `prev` is the `{` of
/// a block or container, the `;` or `}` that ends a statement or member, or the `,` that ends a
/// field; without `prev`, the file. Null at other positions
fn scopeAfter(arena: Allocator, root: SyntaxNode, prev: ?SyntaxToken) Allocator.Error!?SyntaxNode {
    const p = prev orelse return root;
    switch (p.kind) {
        .l_brace, .semicolon, .comma, .r_brace => {},
        else => return null,
    }
    const path = try root.coveringPath(arena, p.offset);
    var i = path.len - 1;
    switch (p.kind) {
        .l_brace => return path[i],
        // Statements that end with a block (`if`, `while`, `switch`, etc.) need no semicolon
        .r_brace => switch (path[i].kind()) {
            .block, .switch_expr => {},
            else => return null,
        },
        else => {},
    }
    // Outside the statement or member that ends at `prev`
    const end = p.range().end;
    while (i > 0 and path[i].range().end == end) i -= 1;
    const node = path[i];
    if (p.kind == .comma and node.kind() != .container_decl and node.kind() != .source_file) return null;
    return node;
}

/// Functions complete as calls (`f(${1:a}, ${2:b})`), skipping the receiver parameter for members
/// of a value (method calls); builtins complete as calls too. Only the name is inserted when `(`
/// already follows the cursor or the position expects a function value (see `expectsFnValue`).
/// When completing in scope, declaration names and names at the start of a container member do not
/// complete as calls
fn addCallSnippets(r: *Resolver, file: FileId, text: []const u8, root: SyntaxNode, offset: u32, visible: Visible, pos: ?Position, items: []Item, placeholders: bool) resolve.Error!void {
    const word: ?Item.Range = switch (visible.context) {
        // Builtin items already have a replace range
        .builtin => null,
        .member, .enum_literal => callWord(root, text, offset, visible.context) orelse return,
        .scope => blk: {
            const p = pos orelse return;
            if (p.kind == .member or p.after_pub) return;
            if (p.prev) |prev| switch (prev.kind) {
                .keyword_const, .keyword_var, .keyword_fn, .keyword_test => return,
                else => {},
            };
            break :blk callWord(root, text, offset, .scope) orelse return;
        },
        else => return,
    };
    const bound = visible.context == .member and visible.bound;
    var fn_value: ?bool = null;
    for (items) |*it| {
        const range = it.replace orelse word orelse continue;
        if (range.end < text.len and text[range.end] == '(') continue;
        it.snippet = switch (it.kind) {
            .builtin => try builtinSnippet(r.arena, builtins.get(it.label) orelse continue, placeholders),
            .function, .method => blk: {
                const w = word orelse continue;
                const def = try calledFn(r, it.target) orelse continue;
                if (fn_value == null) fn_value = try expectsFnValue(r, file, root, offset, visible, w);
                if (fn_value.?) continue;
                break :blk try callSnippet(r, def, it.label, bound or it.bound, placeholders);
            },
            else => continue,
        };
        it.replace = range;
    }
}

/// Range replaced by a call: from the name before the cursor (from the cursor when there is none)
/// to the end of the identifier characters after it. Null when the word before the cursor is a
/// keyword or a number, or, when completing in scope, not a name in an expression (a declaration
/// name, a capture name, etc.)
fn callWord(root: SyntaxNode, text: []const u8, offset: u32, ctx: Visible.Context) ?Item.Range {
    if (offset > 0) if (root.tokenAtOffset(offset - 1)) |t| if (t.kind == .identifier) {
        if (ctx == .scope and tokenParent(root, offset - 1) != .name_ref) return null;
        return .{ .start = t.offset, .end = t.range().end };
    };
    if (offset > 0 and isIdentChar(text[offset - 1])) return null;
    return .{ .start = offset, .end = identEnd(text, offset) };
}

/// The function declaration an item refers to: the function, or the function an alias refers to
fn calledFn(r: *Resolver, target: ?imports.Target) resolve.Error!?resolve.Def {
    const d = switch (target orelse return null) {
        .decl => |d| d,
        .file => return null,
    };
    const it = (try r.itemTree(d.file)).items[d.item];
    switch (it.kind) {
        .@"fn" => return .{ .item = .{ .file = d.file, .item = d.item } },
        .@"const" => {
            const t = try fnTarget(r, try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = d.file, .item = it.ast_id } })) orelse return null;
            return .{ .item = .{ .file = t.decl.file, .item = t.decl.item } };
        },
        else => return null,
    }
}

/// Snippet calling `def`: the placeholders of the parameters come from `CallParams`; when `bound`,
/// the first parameter (the receiver) is skipped. Without placeholders the cursor stops inside the
/// parentheses; with varargs `...` the last stop is before the `)`, where the remaining arguments
/// can follow
fn callSnippet(r: *Resolver, def: resolve.Def, label: []const u8, bound: bool, placeholders: bool) resolve.Error![]const u8 {
    const d = def.item;
    const params = try r.ctx.get(CallParams, .{ .file = d.file, .item = (try r.itemTree(d.file)).items[d.item].ast_id });
    var out: std.ArrayList(u8) = .empty;
    try appendEscaped(r.arena, &out, label);
    try out.append(r.arena, '(');
    var n: u32 = 0;
    var rest = false;
    // Varargs `...` come after `names`
    const total = params.names.len + @intFromBool(params.varargs);
    for (@min(@intFromBool(bound), total)..total) |i| {
        if (!placeholders or i == params.names.len) {
            rest = true;
            break;
        }
        if (n > 0) try out.appendSlice(r.arena, ", ");
        n += 1;
        try out.print(r.arena, "${{{d}:", .{n});
        try appendEscaped(r.arena, &out, params.names[i]);
        try out.append(r.arena, '}');
    }
    if (rest) try out.print(r.arena, "${d}", .{n + 1});
    try out.append(r.arena, ')');
    return out.items;
}

/// Placeholders of the parameters of a function declaration in call snippets. The value is small
/// and never evicted: the functions listed by completion are spread across many files, which then
/// need not be parsed again after their parse results are evicted
pub const CallParams = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = database.hir.OwnerKey;
    pub const Value = struct {
        arena: std.heap.ArenaAllocator.State,
        /// Placeholders of the parameters before varargs `...`: the parameter name, or the type
        /// when the parameter has no name or is `_`
        names: []const []const u8,
        /// The last parameter is varargs `...`
        varargs: bool,
    };

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var arena: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        var varargs = false;
        const node = (try ctx.get(database.syntax.FileAstIdMap, key.file)).get(key.item);
        if (node) |n| if (ast.cast(ast.FnDecl, n)) |f| if (f.proto()) |proto| {
            var params = proto.params();
            while (params.next()) |p| {
                const param = ast.cast(ast.Param, p).?;
                if (param.syntax.childToken(.ellipsis3) != null) {
                    varargs = true;
                    break;
                }
                try names.append(a, try placeholder(a, param));
            }
        };
        return .{ .arena = arena.state, .names = names.items, .varargs = varargs };
    }

    fn placeholder(a: Allocator, p: ast.Param) Allocator.Error![]const u8 {
        if (p.name()) |t| if (!std.mem.eql(u8, t.text, "_")) return a.dupe(u8, t.text);
        if (p.typeExpr()) |t| return ast.collapsedAlloc(a, t);
        return "anytype";
    }

    pub fn eql(x: Value, y: Value) bool {
        if (x.varargs != y.varargs or x.names.len != y.names.len) return false;
        for (x.names, y.names) |p, q| if (!std.mem.eql(u8, p, q)) return false;
        return true;
    }

    pub fn bytes(v: Value) usize {
        return mem.arenaBytes(v.arena);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        var arena = v.arena.promote(gpa);
        arena.deinit();
    }
};

/// Snippet calling a builtin: the placeholders are the names of the documented parameters (without
/// `comptime`, `noalias` and the types); varargs as in `callSnippet`. For a builtin without
/// documented parameters, the parameter count of the compiler decides whether arguments are needed
fn builtinSnippet(arena: Allocator, entry: *const builtins.Entry, placeholders: bool) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendEscaped(arena, &out, entry.name);
    try out.append(arena, '(');
    var n: u32 = 0;
    var rest = false;
    for (entry.parameters) |raw| {
        var param = std.mem.trim(u8, raw, " \t\r\n");
        if (!placeholders or std.mem.eql(u8, param, "...")) {
            rest = true;
            break;
        }
        for ([_][]const u8{ "comptime ", "noalias " }) |prefix| {
            if (std.mem.startsWith(u8, param, prefix)) param = param[prefix.len..];
        }
        if (std.mem.indexOfScalar(u8, param, ':')) |colon| param = std.mem.trimEnd(u8, param[0..colon], " ");
        if (n > 0) try out.appendSlice(arena, ", ");
        n += 1;
        try out.print(arena, "${{{d}:", .{n});
        try appendEscaped(arena, &out, param);
        try out.append(arena, '}');
    }
    if (rest or (n == 0 and (entry.compiler_param_count orelse 1) > 0)) try out.print(arena, "${d}", .{n + 1});
    try out.append(arena, ')');
    return out.items;
}

/// Text inserted verbatim in a snippet: escapes `$`, `}` and `\`
fn appendEscaped(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| {
        if (c == '$' or c == '}' or c == '\\') try out.append(arena, '\\');
        try out.append(arena, c);
    }
}

/// Position of a name in an expression
const Slot = union(enum) {
    none,
    /// `&f`, the callee of `@call`
    fn_value,
    /// Argument `index` of the call `call`
    arg: struct { call: Body.ExprId, index: u32 },
    /// Value of field `index` in the initializer `init`
    field: struct { init: Body.ExprId, index: u32 },
    /// Element `index` of the array or tuple initializer `init`
    elem: struct { init: Body.ExprId, index: u32 },
    /// Right-hand side of an assignment (`=`); the payload is the left-hand side
    assign: Body.ExprId,
    /// Initializer of a local variable
    local: Body.BindingId,
    /// Value of a member: the initializer of a variable, the default value of a field
    value,
    @"return",
};

/// The position of the name at the cursor expects a function value: `&f`, the callee of `@call`,
/// and arguments, fields, array and tuple elements, assignments, variables and return values whose
/// type is a function or a function pointer (including inside optionals and error unions). The
/// branches of `if`, `switch`, `orelse`, `catch` and the value of `break :label` take the position
/// of the expression they produce
fn expectsFnValue(r: *Resolver, file: FileId, root: SyntaxNode, offset: u32, visible: Visible, word: Item.Range) resolve.Error!bool {
    const a = visible.at orelse try context.atSeeded(r, file, offset, true) orelse return false;
    const slot: Slot = switch (visible.context) {
        .member => exprSlot(a.body, a.rel, .field_access),
        .scope => if (word.start < offset) exprSlot(a.body, a.rel, .name_ref) else try emptySlot(r.arena, root, a, offset),
        else => return false,
    };
    return slotIsFn(r, a, slot);
}

/// Position of the expression containing the character before the cursor, which must be a `tag`
fn exprSlot(b: *const Body, rel: u32, tag: std.meta.Tag(Body.Expr)) Slot {
    if (rel == 0) return .none;
    const e = b.exprAt(rel - 1) orelse return .none;
    return if (std.meta.activeTag(b.expr(e)) == tag) slotOf(b, e) else .none;
}

fn slotOf(b: *const Body, e: Body.ExprId) Slot {
    for (b.exprs, 0..) |x, i| {
        const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
        switch (x) {
            .prefix => |p| if (p.operand == e and p.op == .ampersand) return .fn_value,
            .builtin_call => |c| if (std.mem.eql(u8, c.name, "@call") and c.args.len > 1 and c.args[1] == e) return .fn_value,
            .call => |c| for (c.args, 0..) |arg, j| {
                if (arg == e) return .{ .arg = .{ .call = id, .index = @intCast(j) } };
            },
            .init => |init| for (init.fields, 0..) |f, j| {
                if (f.value == e) return if (f.name != null) .{ .field = .{ .init = id, .index = @intCast(j) } } else .{ .elem = .{ .init = id, .index = @intCast(j) } };
            },
            .assign => |x_| if (x_.rhs == e and x_.op == .equal) return .{ .assign = x_.lhs },
            .@"return" => |v| if (v == e) return .@"return",
            // A branch value takes the position of the whole expression
            .@"if" => |x_| if (x_.then == e or x_.@"else" == e) return slotOf(b, id),
            .@"switch" => |s| for (s.prongs) |prong| {
                if (prong.body == e) return slotOf(b, id);
            },
            .binary => |x_| if (x_.op == .keyword_orelse and x_.rhs == e) return slotOf(b, id),
            .@"catch" => |c| if (c.rhs == e) return slotOf(b, id),
            .@"comptime" => |inner| if (inner == e) return slotOf(b, id),
            .@"break" => |x_| if (x_.value == e) {
                const block = labeledBlock(b, id, x_.label orelse return .none) orelse return .none;
                return slotOf(b, block);
            },
            else => {},
        }
    }
    for (b.bindings, 0..) |binding, i| if (binding.init) |init| if (init == e) return .{ .local = @fromBackingInt(@as(u32, @intCast(i))) };
    if (b.value == e) return .value;
    return .none;
}

/// Position at the cursor when no name precedes it: the expression is missing and has no position
/// in the Body, so the position follows from the token before the cursor
fn emptySlot(arena: Allocator, root: SyntaxNode, a: context.At, offset: u32) Allocator.Error!Slot {
    const b = a.body;
    const p = tokenBefore(root, offset) orelse return .none;
    if (p.offset < a.node.offset) return .none;
    const rel = p.offset - a.node.offset;
    if (b.exprAt(rel)) |e| switch (b.expr(e)) {
        .call => |c| if (p.kind == .l_paren or p.kind == .comma) return .{ .arg = .{ .call = e, .index = argsBefore(b, c.args, rel) } },
        .builtin_call => |c| if (p.kind == .comma and std.mem.eql(u8, c.name, "@call") and argsBefore(b, c.args, rel) == 1) return .fn_value,
        .prefix => |x| if (p.kind == .ampersand and x.op == .ampersand) return .fn_value,
        .@"return" => if (p.kind == .keyword_return) return .@"return",
        .init => |init| switch (p.kind) {
            .equal => {
                // The last field name before the `=`
                var index: ?usize = null;
                for (init.fields, 0..) |f, j| {
                    if (f.name != null and f.name_range.end <= rel) index = j;
                }
                if (index) |j| return .{ .field = .{ .init = e, .index = @intCast(j) } };
            },
            // An element of an array or tuple initializer: the elements before the cursor are
            // counted (missing elements have no position)
            .l_brace, .comma => {
                var index: u32 = 0;
                for (init.fields) |f| {
                    if (f.name != null) return .none;
                    const range = b.range(f.value);
                    if (range.end > range.start and range.end <= rel) index += 1;
                }
                return .{ .elem = .{ .init = e, .index = index } };
            },
            else => {},
        },
        .assign => |x| if (p.kind == .equal and x.op == .equal) return .{ .assign = x.lhs },
        else => {},
    };
    if (p.kind != .equal) return .none;
    // Variables and fields whose initializer is not written yet (`const f: T = `)
    const path = try root.coveringPath(arena, p.offset);
    const decl = path[path.len - 1];
    if (decl.offset == a.node.offset) return switch (decl.kind()) {
        .var_decl, .container_field => .value,
        else => .none,
    };
    if (decl.kind() != .var_decl) return .none;
    const name = (ast.VarDecl{ .syntax = decl }).name() orelse return .none;
    for (b.bindings, 0..) |binding, i| {
        if (binding.kind != .param and binding.range.start == name.offset - a.node.offset) return .{ .local = @fromBackingInt(@as(u32, @intCast(i))) };
    }
    return .none;
}

/// Number of arguments that end before `rel` (missing arguments have no position and are not
/// counted)
fn argsBefore(b: *const Body, args: []const Body.ExprId, rel: u32) u32 {
    var n: u32 = 0;
    for (args) |arg| {
        const range = b.range(arg);
        if (range.end > range.start and range.end <= rel) n += 1;
    }
    return n;
}

fn slotIsFn(r: *Resolver, a: context.At, slot: Slot) resolve.Error!bool {
    const b = a.body;
    switch (slot) {
        .none => return false,
        .fn_value => return true,
        .arg => |arg| {
            const c = try context.callee(r, a, b.expr(arg.call).call.callee) orelse return false;
            return paramIsFn(r, c.def, arg.index + @intFromBool(c.bound));
        },
        .field => |f| {
            const key = a.fieldRef(f.init, f.index) orelse return false;
            if (isFnType(a.ip, (try r.ctx.get(queries.DeclType, .{ .owner = key })).ty)) return true;
            const def = try context.defOfKey(r, key) orelse return false;
            const fb = try r.body(def.item.file, def.item.item);
            return if (fb.type_expr) |t| isFnTypeExpr(fb, t) else false;
        },
        .elem => |el| {
            // By syntax (`[_]*const fn () void{ ... }`), or by the computed type of the initializer
            if (b.expr(el.init).init.ty) |t| switch (b.expr(t)) {
                .array_type => |arr| if (isFnTypeExpr(b, arr.child)) return true,
                else => {},
            };
            return switch (a.ip.key(a.exprType(el.init).ty)) {
                .array_type => |arr| isFnType(a.ip, arr.child),
                .abstract_array_type => |arr| isFnType(a.ip, arr.child),
                .tuple_type => |tuple| el.index < tuple.types.len and isFnType(a.ip, tuple.types[el.index]),
                else => false,
            };
        },
        .assign => |lhs| return isFnType(a.ip, a.exprType(lhs).ty),
        .local => |id| return typeExprIsFn(a, b.binding(id).ty),
        .value, .@"return" => return typeExprIsFn(a, b.type_expr),
    }
}

/// The type of parameter `index` of the function `def` is a function or a function pointer, or the
/// parameter is `anytype` and receives a function (see `receivesFn`)
fn paramIsFn(r: *Resolver, def: resolve.Def, index: u32) resolve.Error!bool {
    const d = switch (def) {
        .item => |d| d,
        else => return false,
    };
    const it = (try r.itemTree(d.file)).items[d.item];
    if (it.kind != .@"fn") return false;
    const fb = try r.body(d.file, d.item);
    if (index < fb.params.len) {
        if (fb.binding(fb.params[index]).ty) |t| {
            if (isFnTypeExpr(fb, t)) return true;
        } else if (try receivesFn(r, d.file, d.item, fb, fb.params[index])) return true;
    }
    const ip = r.ctx.db.env.ip;
    return switch (ip.key((try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = d.file, .item = it.ast_id } })).ty)) {
        .fn_type => |f| index < f.params.len and isFnType(ip, f.params[index]),
        else => false,
    };
}

/// The `anytype` parameter `param` receives a function: the type of another parameter is
/// `std.meta.ArgsTuple(@TypeOf(param))`, which accepts only function types (`Io.async(io, function,
/// args)`)
fn receivesFn(r: *Resolver, file: FileId, item: u32, fb: *const Body, param: Body.BindingId) resolve.Error!bool {
    const name = fb.binding(param).name;
    for (fb.params) |other| {
        const t = fb.binding(other).ty orelse continue;
        const call = switch (fb.expr(t)) {
            .call => |c| c,
            else => continue,
        };
        if (call.args.len != 1) continue;
        const type_of = switch (fb.expr(call.args[0])) {
            .builtin_call => |c| c,
            else => continue,
        };
        if (!std.mem.eql(u8, type_of.name, "@TypeOf") or type_of.args.len != 1) continue;
        const arg = type_of.args[0];
        switch (fb.expr(arg)) {
            .name_ref => |n| if (!std.mem.eql(u8, n, name)) continue,
            else => continue,
        }
        const local = try r.resolveName(file, item, fb, fb.expr_scopes[@backingInt(arg)], name) orelse continue;
        if (local != .local or local.local.binding != param) continue;
        const callee: resolve.Def = switch (fb.expr(call.callee)) {
            .name_ref => |n| try r.resolveName(file, item, fb, fb.expr_scopes[@backingInt(call.callee)], n),
            .field_access => |fa| if (try r.evalNamespace(file, item, fb, fa.lhs)) |ns| try r.memberDef(ns, fa.field orelse continue) else null,
            else => null,
        } orelse continue;
        const args_tuple = try stdDecl(r, file, &.{ "meta", "ArgsTuple" }) orelse return false;
        if (std.meta.eql(try r.aliasTarget(callee), args_tuple)) return true;
    }
    return false;
}

/// The type annotation is a function or a function pointer: by syntax, or by the computed type (for
/// aliases)
fn typeExprIsFn(a: context.At, t: ?Body.ExprId) bool {
    const e = t orelse return false;
    if (isFnTypeExpr(a.body, e)) return true;
    return if (a.exprType(e).asType()) |ty| isFnType(a.ip, ty) else false;
}

/// Function types, single pointers to functions, and optionals and error unions of them
fn isFnTypeExpr(b: *const Body, e: Body.ExprId) bool {
    var cur = e;
    while (true) cur = switch (b.expr(cur)) {
        .optional_type => |child| child,
        .error_union_type => |eu| eu.payload,
        .ptr_type => |p| if (p.size == .one) p.child else return false,
        .fn_type => return true,
        else => return false,
    };
}

/// Like `isFnTypeExpr`, for a computed type
fn isFnType(ip: *InternPool, t: Index) bool {
    var cur = t;
    while (true) cur = switch (ip.key(cur)) {
        .optional_type => |child| child,
        .error_union_type => |eu| eu.payload,
        .ptr_type => |p| if (p.size == .one) p.child else return false,
        .fn_type => return true,
        else => return false,
    };
}

const Snippet = struct {
    label: []const u8,
    text: []const u8,
    /// Cannot follow `pub`
    no_pub: bool = false,
    /// Cannot have a doc comment
    no_doc: bool = false,
};

/// Snippets at the start of a statement
const statement_snippets = [_]Snippet{
    .{ .label = "if", .text = "if ($1) {$0}" },
    .{ .label = "if else", .text = "if ($1) {$2} else {$0}" },
    .{ .label = "for", .text = "for ($1) |${2:value}| {$0}" },
    .{ .label = "fori", .text = "for ($1, 0..) |${2:value}, ${3:i}| {$0}" },
    .{ .label = "while", .text = "while ($1) {$0}" },
    .{ .label = "switch", .text = "switch ($1) {$0}" },
};

/// Snippets at the start of a statement when `std` is the standard library
const std_statement_snippets = [_]Snippet{
    .{ .label = "print", .text = "std.debug.print(\"$1\", .{$0});" },
    .{ .label = "log err", .text = "std.log.err(\"$1\", .{$0});" },
    .{ .label = "log warn", .text = "std.log.warn(\"$1\", .{$0});" },
    .{ .label = "log info", .text = "std.log.info(\"$1\", .{$0});" },
    .{ .label = "log debug", .text = "std.log.debug(\"$1\", .{$0});" },
};

/// Snippets at the start of a container member
const member_snippets = [_]Snippet{
    .{ .label = "fn", .text = "fn ${1:name}($2) ${3:!void} {$0}" },
    .{ .label = "pub fn", .text = "pub fn ${1:name}($2) ${3:!void} {$0}", .no_pub = true },
    .{ .label = "test", .text = "test \"${1:name}\" {$0}", .no_pub = true, .no_doc = true },
    .{ .label = "struct", .text = "const ${1:Name} = struct {$0};" },
    .{ .label = "enum", .text = "const ${1:Name} = enum {$0};" },
    .{ .label = "union", .text = "const ${1:Name} = union {$0};" },
    .{ .label = "union tagged", .text = "const ${1:Name} = union(${2:enum}) {$0};" },
    .{ .label = "error set", .text = "const ${1:Error} = error{$0};" },
    .{ .label = "import", .text = "const $1 = @import(\"$2\");" },
};

/// Common snippets at the start of a statement or a container member: control flow, printing and
/// logging; declarations of functions, types, tests and imports, and the `main` and `format`
/// functions. Snippets that use `std` are offered only when `std` is the standard library; the
/// `std` and `builtin` imports, `main` and `format` only when not declared yet
fn addKeywordSnippets(r: *Resolver, file: FileId, text: []const u8, offset: u32, visible: Visible, pos: Position, items: *std.ArrayList(Item)) resolve.Error!void {
    switch (visible.context) {
        .none, .scope => {},
        else => return,
    }
    // Inside a number literal
    if (pos.start < offset and std.ascii.isDigit(text[pos.start])) return;
    const range: Item.Range = .{ .start = pos.start, .end = pos.end };
    switch (pos.kind) {
        .statement => {
            if (visible.context != .scope or pos.after_pub or pos.doc) return;
            for (statement_snippets) |s| try addSnippet(r.arena, items, s.label, s.text, range);
            const b = try r.body(file, visible.item);
            if (try isStd(r, file, try r.resolveName(file, visible.item, b, visible.scope, "std"))) {
                for (std_statement_snippets) |s| try addSnippet(r.arena, items, s.label, s.text, range);
            }
        },
        .member => {
            const node = pos.node.?;
            if (betweenFields(node, pos.start, pos.end)) return;
            const container = try containerIndex(r, file, node) orelse return;
            for (member_snippets) |s| {
                if ((pos.after_pub and s.no_pub) or (pos.doc and s.no_doc)) continue;
                try addSnippet(r.arena, items, s.label, s.text, range);
            }
            const std_def = try r.resolveInContainer(file, container, "std");
            if (!pos.after_pub) {
                if (std_def == null) try addSnippet(r.arena, items, "std", "const std = @import(\"std\");", range);
                if (try r.resolveInContainer(file, container, "builtin") == null) try addSnippet(r.arena, items, "builtin", "const builtin = @import(\"builtin\");", range);
            }
            const is_std = try isStd(r, file, std_def);
            const tree = try r.itemTree(file);
            // Drop the leading `pub ` when `pub` is already written
            const skip: usize = if (pos.after_pub) "pub ".len else 0;
            if (container == 0 and Resolver.lookupDecl(tree, 0, "main") == null) {
                const main = if (is_std and try stdHas(r, file, &.{ "process", "Init" }))
                    "pub fn main(init: std.process.Init) !void {$0}"
                else
                    "pub fn main() !void {$0}";
                try addSnippet(r.arena, items, "main", main[skip..], range);
            }
            // `format` belongs to types: containers other than the file, and the file when it has
            // fields (a file used as a struct)
            const is_type = container != 0 or for (tree.containerMembers(0)) |m| {
                if (tree.items[m].kind == .field) break true;
            } else false;
            if (is_type and is_std and tree.containers[container].kind != .@"opaque" and
                Resolver.lookupDecl(tree, container, "format") == null and try stdHas(r, file, &.{ "Io", "Writer" }))
            {
                const format = "pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {$0}";
                try addSnippet(r.arena, items, "format", format[skip..], range);
            }
        },
        .other => {},
    }
}

fn addSnippet(arena: Allocator, items: *std.ArrayList(Item), label: []const u8, snippet: []const u8, range: Item.Range) Allocator.Error!void {
    try items.append(arena, .{ .label = label, .kind = .snippet, .detail = try preview(arena, snippet), .replace = range, .snippet = snippet, .weight = snippet_weight });
}

/// How a snippet looks once inserted: placeholders take their default text, empty placeholders
/// show as `…`, and the final position `$0` is dropped
fn preview(arena: Allocator, snippet: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < snippet.len) {
        const c = snippet[i];
        if (c == '\\' and i + 1 < snippet.len) {
            try out.append(arena, snippet[i + 1]);
            i += 2;
        } else if (c == '$' and i + 1 < snippet.len and std.ascii.isDigit(snippet[i + 1])) {
            var j = i + 1;
            while (j < snippet.len and std.ascii.isDigit(snippet[j])) j += 1;
            if (!std.mem.eql(u8, snippet[i + 1 .. j], "0")) try out.appendSlice(arena, "…");
            i = j;
        } else if (c == '$' and i + 1 < snippet.len and snippet[i + 1] == '{') {
            i += 2;
            while (i < snippet.len and std.ascii.isDigit(snippet[i])) i += 1;
            if (i < snippet.len and snippet[i] == ':') i += 1;
            while (i < snippet.len and snippet[i] != '}') : (i += 1) {
                if (snippet[i] == '\\' and i + 1 < snippet.len) i += 1;
                try out.append(arena, snippet[i]);
            }
            i += 1;
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

/// `def` is the standard library (`@import("std")`)
fn isStd(r: *Resolver, file: FileId, def: ?resolve.Def) resolve.Error!bool {
    const d = def orelse return false;
    const std_file = try r.resolveImport(file, "std") orelse return false;
    const ns = try r.namespaceOf(d) orelse return false;
    return ns.file == std_file and ns.container == 0;
}

/// The standard library declares `path` (such as `process.Init`)
fn stdHas(r: *Resolver, file: FileId, path: []const []const u8) resolve.Error!bool {
    return try stdDecl(r, file, path) != null;
}

/// The declaration `path` of the standard library
fn stdDecl(r: *Resolver, file: FileId, path: []const []const u8) resolve.Error!?resolve.Def {
    var ns: Namespace = .{ .file = try r.resolveImport(file, "std") orelse return null, .container = 0 };
    for (path, 0..) |name, i| {
        const def = try r.memberDef(ns, name) orelse return null;
        if (i + 1 == path.len) return def;
        ns = try r.namespaceOf(def) orelse return null;
    }
    return null;
}

/// The container has fields both before and after the range `start..end`: declarations cannot be
/// placed between fields
fn betweenFields(container: SyntaxNode, start: u32, end: u32) bool {
    var before = false;
    var after = false;
    var it = container.children();
    while (it.nextNode()) |c| {
        if (c.kind() != .container_field) continue;
        if (c.range().end <= start) before = true;
        if (c.range().start >= end) after = true;
    }
    return before and after;
}

/// Index of the container node in the ItemTree
fn containerIndex(r: *Resolver, file: FileId, node: SyntaxNode) resolve.Error!?u32 {
    if (node.kind() == .source_file) return 0;
    const n = (try r.itemTree(file)).containers.len;
    for (1..n) |i| {
        if (try r.containerOffset(.{ .file = file, .container = @intCast(i) })) |o| if (o == node.offset) return @intCast(i);
    }
    return null;
}
