//! Completion: after `a.`, lists the members of the namespace; after `.`, lists members by the
//! expected type, and in initializers the fields not yet assigned; after `error.`, lists error
//! names; after `@`, lists builtins; inside `@import("`, lists modules and files; after `break :` /
//! `continue :`, lists labels; otherwise lists the names visible at the cursor (local names and
//! the declarations of enclosing containers).
//! No completion in comments and strings (other than `@import("`).

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
const imports = @import("../ide_db/imports.zig");
const SyntaxNode = @import("../syntax/tree.zig").SyntaxNode;
const ast = @import("../syntax/ast.zig");
const isTrivia = @import("../syntax/kind.zig").isTrivia;
const fuzzy = @import("../ide_db/fuzzy.zig");

pub const Options = struct {
    auto_import: bool = true,
    /// Even when auto-import is not offered, determine whether the cursor is at a name that can be
    /// auto-imported (`Result.import_position`)
    detect_import_position: bool = false,
    /// Maximum number of auto-import candidates offered (the best-ranked ones are kept);
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

    pub const Kind = enum { param, type_param, constant, variable, function, method, namespace, @"struct", @"enum", type, field, enum_member, error_name, builtin, module, file, folder, label };
    pub const Range = struct { start: u32, end: u32 };
};

pub fn complete(r: *Resolver, file: FileId, offset: u32, options: Options) resolve.Error!Result {
    var owner: imports.Owner = .unknown;
    const base = try completeVisible(r, file, offset, &owner);
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
    if (options.auto_import) {
        const extra = try imports.complete(r, file, offset, owner, name.prefix, options.max_auto_imports, options.imports);
        result.is_incomplete = extra.is_incomplete;
        for (extra.items) |candidate| {
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
            try items.append(r.arena, .{
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
            });
        }
    }
    try rank(r.arena, items.items, name.prefix);
    result.items = items.items;
    return result;
}

/// Order of name completion (`Item.sort`): the score of a name in scope is its match score (see
/// `fuzzy`) multiplied by its source weight (`Item.weight`), and an auto-import candidate takes
/// its own score (see `imports.Candidate.score`); from high to low, keeping the collection order
/// among equal scores. Names in scope that do not match the input score 0, sort last, and are
/// filtered by the client.
fn rank(arena: Allocator, items: []Item, prefix: []const u8) Allocator.Error!void {
    var matcher: fuzzy.Matcher = try .init(arena, prefix);
    for (items) |*it| if (it.weight != 0) {
        it.score = ((try matcher.score(it.label)) orelse 0) * it.weight;
    };
    std.mem.sort(Item, items, {}, struct {
        fn higher(_: void, a: Item, b: Item) bool {
            return a.score > b.score;
        }
    }.higher);
    for (items, 0..) |*it, i| it.sort = try std.fmt.allocPrint(arena, "{d:0>5}", .{i});
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

/// `cursor_owner` records the member found at the cursor, which auto-import reuses
fn completeVisible(r: *Resolver, file: FileId, offset: u32, cursor_owner: *imports.Owner) resolve.Error![]const Item {
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
    if (literal == .string) return &.{};

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
            const ty = if (x.ty == null) a.literalExpected(init) orelse return &.{} else a.exprType(init).ty;
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
    const types: BindingTypes = if (try context.atSeeded(r, file, offset, true)) |a| .{ .at = a } else .none;
    try locals(&out, r.ctx.db.env.ip, b, scope, null, types);

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
        try locals(&out, r.ctx.db.env.ip, pb, pb.scopeAt(c_node.offset - owner.offset), weight, .{ .res = parent_res });
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
/// `weight` (names in an enclosing function)
fn locals(out: *Collector, ip: *InternPool, b: *const Body, from: Body.ScopeId, weight: ?f32, types: BindingTypes) Allocator.Error!void {
    var s: ?Body.ScopeId = from;
    while (s) |id| : (s = b.scope(id).parent) {
        for (b.scope(id).bindings) |bid| {
            const binding = b.binding(bid);
            try out.add(.{
                .label = binding.name,
                .kind = kindOf(symbol_kind.ofBinding(ip, binding, types.of(bid))),
                .weight = weight orelse if (binding.kind == .param) param_weight else local_weight,
            });
        }
    }
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
        try out.add(.{ .label = name, .kind = kind, .doc = it.doc, .target = if (it.kind == .@"fn") .{ .decl = .{ .file = file, .item = m } } else null, .weight = weight });
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
    const slash = std.mem.lastIndexOfScalar(u8, typed, '/');
    if (slash == null) {
        for ([_][]const u8{ "std", "builtin", "root" }) |m| try out.add(.{ .label = m, .kind = .module, .replace = range });
        if (try r.ctx.get(ModuleGraph.Input, {})) |graph| {
            for (try graph.importNames(r.arena, file)) |name| try out.add(.{ .label = name, .kind = .module, .replace = range });
        }
    }
    const vfs = r.ctx.db.env.vfs;
    const prefix = if (slash) |s| typed[0 .. s + 1] else "";
    const base = std.fs.path.dirname(vfs.path(file)) orelse return;
    const dir_path = try std.fs.path.join(r.arena, &.{ base, prefix });
    var dir = std.Io.Dir.cwd().openDir(vfs.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(vfs.io);
    var it = dir.iterate();
    while (it.next(vfs.io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.' or std.mem.eql(u8, entry.name, "zig-out")) continue;
        switch (entry.kind) {
            .directory => try out.add(.{ .label = try std.fmt.allocPrint(r.arena, "{s}{s}/", .{ prefix, entry.name }), .kind = .folder, .replace = range }),
            .file => if (std.mem.endsWith(u8, entry.name, ".zig") or std.mem.endsWith(u8, entry.name, ".zon")) {
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
