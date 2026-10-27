//! 补全：`a.` 之后列出命名空间的成员；`.` 之后按期望类型列出成员，初始化中列出未赋值的字段；
//! `error.` 之后列出错误名；`@` 之后列出内置函数；`@import("` 中列出模块与文件；
//! `break :` / `continue :` 之后列出标签；否则列出光标处可见的名字（局部名字与外层容器的声明）。
//! 注释与字符串中（`@import("` 之外）不补全。

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const ItemTree = @import("../syntax/ItemTree.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const context = @import("context.zig");
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

pub const Options = struct {
    auto_import: bool = true,
    /// 不提供自动导入时也判断光标是否位于可以自动导入的名字处（`Result.import_position`）
    detect_import_position: bool = false,
    /// 至多提供的自动导入候选（保留排序最好的）；不限时为 `maxInt(usize)`
    max_auto_imports: usize = 128,
    /// 自动导入的新 import 按它放到整理好的 import 块中应在的位置（配置 `imports.*`）
    imports: @import("../ide_db/organize_imports.zig").Options = .{},
};

pub const Result = struct {
    items: []const Item,
    is_incomplete: bool = false,
    /// 光标位于可以自动导入的名字处（提供了自动导入，或要求判断时）
    import_position: bool = false,
};

pub const Item = struct {
    label: []const u8,
    kind: Kind,
    /// 文档注释
    doc: ?[]const u8 = null,
    /// 类型
    detail: ?[]const u8 = null,
    /// 替换的范围（文件中的字节偏移，插入的文本为 `label`）；null 时由客户端按单词确定。
    /// `@`、路径中的 `/` 等不属于单词的字符需要它
    replace: ?Range = null,
    filter: ?[]const u8 = null,
    qualifier: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    import_edit: ?imports.Edit = null,
    /// 所指的定义，被选中时据此给出签名与文档（见 `describe`）：自动导入的候选与函数
    target: ?imports.Target = null,

    pub const Kind = enum { param, local, capture, function, constant, variable, field, enum_member, error_name, builtin, module, file, folder, label };
    pub const Range = struct { start: u32, end: u32 };
};

pub fn complete(r: *Resolver, file: FileId, offset: u32, options: Options) resolve.Error!Result {
    var owner: imports.Owner = .unknown;
    const base = try completeVisible(r, file, offset, &owner);
    if (!options.auto_import and !options.detect_import_position) return .{ .items = base };
    // 只在 Zig 源文件中自动导入：向 `.zon` 等文件插入 import 声明会破坏它
    if (!imports.isZigSource(r.ctx.db.env.vfs.path(file))) return .{ .items = base };
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    if (offset == 0 or offset > text.len) return .{ .items = base };
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const name = try importPrefix(r.arena, root, text, offset) orelse return .{ .items = base };
    if (!options.auto_import) return .{ .items = base, .import_position = true };
    const extra = try imports.complete(r, file, offset, owner, name.prefix, options.max_auto_imports, options.imports);
    if (extra.items.len == 0) return .{ .items = base, .is_incomplete = extra.is_incomplete, .import_position = true };
    var items: std.ArrayList(Item) = .empty;
    try items.appendSlice(r.arena, base);
    for (extra.items) |candidate| {
        // 核心已经逐段渲染了路径，不能把整个限定表达式再次当作标识符转义。
        const filter = try completionFilter(r.arena, name, candidate.filter);
        var duplicate = false;
        for (items.items[0..base.len]) |*visible| if (std.mem.eql(u8, visible.label, candidate.label)) {
            // 只合并可见绑定；不同来源的同名自动导入项必须继续作为独立选择。
            if (candidate.import_edit == null) {
                visible.replace = name.range;
                visible.filter = filter;
                visible.qualifier = candidate.qualifier;
                visible.sort = candidate.sort;
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
                .module => .module,
                .file => .file,
            },
            .doc = candidate.doc,
            .replace = name.range,
            .filter = filter,
            .qualifier = candidate.qualifier,
            .sort = candidate.sort,
            .import_edit = candidate.import_edit,
            .target = candidate.target,
        });
    }
    return .{ .items = items.items, .is_incomplete = extra.is_incomplete, .import_position = true };
}

pub const Description = struct {
    /// 签名（同 hover）；模块与文件为 import 表达式
    detail: []const u8,
    /// markdown：文档注释与定义的位置
    doc: []const u8,
};

/// 补全项被选中时的说明（`completionItem/resolve`）：在 `from` 中补全时所指的定义
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

/// 文件开头的 `//!` 文档，整理方式同 `///` 文档（见 `ItemTree`）；没有时为 null
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

/// `cursor_owner` 记下查到的光标所在成员，自动导入沿用
fn completeVisible(r: *Resolver, file: FileId, offset: u32, cursor_owner: *imports.Owner) resolve.Error![]const Item {
    var out: Collector = .{ .arena = r.arena };
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    if (offset > text.len) return &.{};

    const literal = try commentOrString(r, file, offset);
    if (literal == .comment) return &.{};
    // 以下几种上下文在语法树中多为错误节点（如单独的 `@`、未闭合的字符串），直接按源码文本识别
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

    // `lhs.` / `lhs.na`：光标前一个字符在字段访问内、且不在左侧表达式内
    if (rel > 0) if (b.exprAt(rel - 1)) |e| switch (b.expr(e)) {
        .field_access => |fa| if (rel - 1 >= b.range(fa.lhs).end) {
            out.member_mode = true;
            if (try r.evalNamespace(file, item, b, fa.lhs)) |ns| {
                try members(r, &out, ns, ns.file == file);
                return out.items.items;
            }
            // 经由类型：实例的字段与方法（泛型函数体内取调用点的实例）
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

    // `.` / `.na`（枚举字面量、decl literal）：按期望类型列出成员；初始化中（`.{ .x = 1, .| }`）列出未赋值的字段
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

    // 作用域中的名字：光标紧跟在名字之后时取该名字所在的作用域
    const scope = if (rel > 0) if (b.exprAt(rel - 1)) |e| switch (b.expr(e)) {
        .name_ref => b.expr_scopes[@backingInt(e)],
        else => b.scopeAt(rel),
    } else b.scopeAt(rel) else b.scopeAt(rel);
    try locals(&out, b, scope);

    const tree = try r.itemTree(file);
    var container = tree.items[item].container;
    while (true) {
        try decls(&out, file, tree, container, true);
        const parent = tree.containers[container].parent_item orelse break;
        // 体内定义的容器：外层成员在容器位置可见的局部名字
        const owner = try r.itemNode(file, parent) orelse break;
        const c_node = try r.containerNode(.{ .file = file, .container = container }) orelse break;
        const pb = try r.body(file, parent);
        try locals(&out, pb, pb.scopeAt(c_node.offset - owner.offset));
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

/// 只接受表达式中的名字；声明名、成员名、标签与捕获名都不是 name_ref 的直接 token。
fn importPrefix(arena: Allocator, root: SyntaxNode, text: []const u8, offset: u32) Allocator.Error!?ImportPrefix {
    const token = root.tokenAtOffset(offset - 1) orelse return null;
    if (token.kind != .identifier and token.kind != .invalid) return null;
    const parent = tokenParent(root, offset - 1);
    if (parent != .name_ref) return null;
    // enum 成员与 union(enum) 的 tag 没有冒号，解析器把名字放在 container_field 的类型表达式位置。
    // 它们仍是声明名，替换成限定路径会破坏声明。
    if (try isBareEnumOrUnionMember(arena, root, token.offset)) return null;
    const escaped = std.mem.startsWith(u8, token.text, "@\"");
    if (token.kind == .invalid and !escaped) return null;
    const spelling = if (token.kind == .invalid) std.mem.trimEnd(u8, token.text, "\r\n") else token.text;
    const token_end = token.offset + @as(u32, @intCast(spelling.len));
    if (offset <= token.offset or offset > token_end) return null;
    // 错误 token 没有闭引号界定尾部；保留光标后的源码，不把后面的语句误当成名字一起替换。
    const end = if (token.kind == .invalid) offset else token_end;
    const raw = text[token.offset..offset];
    const closed = token.kind == .identifier and offset == end;
    var prefix = raw;
    if (escaped) {
        // 光标在引号内也按已输入的内容匹配；截断转义序列时不猜测名字。
        if (raw.len <= 2) return null;
        const literal: []const u8 = if (closed) raw[1..] else blk: {
            const quoted = try arena.allocSentinel(u8, raw.len, 0);
            @memcpy(quoted[0 .. raw.len - 1], raw[1..]);
            quoted[raw.len - 1] = '"';
            // 补上的引号不能被尚未完成的转义吃掉；只向字符串解码器传入词法闭合的单个字面量。
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

/// enum 的成员与 `union(enum)` 的 tag 是无冒号的 container_field，名字位于类型表达式的位置；struct 的
/// 元组字段没有冒号但类型表达式是真正的类型引用，不在此列。
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

/// 客户端从替换范围起点过滤；保留用户输入的引号和转义拼写，而不是只返回解码后的名字。
fn completionFilter(arena: Allocator, name: ImportPrefix, target: []const u8) Allocator.Error![]const u8 {
    const raw = name.escaped_prefix orelse return target;
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
    /// `.` 之后的成员 / 字段：原始类型与原始值的名字可以不加引号（`S.u8`）
    member_mode: bool = false,

    /// 内层的名字遮蔽外层的同名名字。作用域中的名字一律按 `fmtId` 加引号（原始类型、
    /// 含特殊字符的名字），`.` 之后的成员允许原始名字
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

fn locals(out: *Collector, b: *const Body, from: Body.ScopeId) Allocator.Error!void {
    var s: ?Body.ScopeId = from;
    while (s) |id| : (s = b.scope(id).parent) {
        for (b.scope(id).bindings) |bid| {
            const binding = b.binding(bid);
            try out.add(.{ .label = binding.name, .kind = switch (binding.kind) {
                .param => .param,
                .local_const, .local_var => .local,
                .capture => .capture,
            } });
        }
    }
}

fn decls(out: *Collector, file: FileId, tree: *const ItemTree, container: u32, private: bool) Allocator.Error!void {
    const is_enum = tree.containers[container].kind == .@"enum";
    for (tree.containerMembers(container)) |m| {
        const it = tree.items[m];
        const name = it.name orelse continue;
        const kind: Item.Kind = switch (it.kind) {
            .@"fn" => .function,
            .@"const" => .constant,
            .@"var" => .variable,
            // 字段不是作用域中的名字；枚举成员可以通过类型访问
            .field => if (is_enum and !private) .enum_member else continue,
            .@"test", .@"comptime" => continue,
        };
        if (!private and it.kind != .field and !it.flags.is_pub) continue;
        try out.add(.{ .label = name, .kind = kind, .doc = it.doc, .target = if (it.kind == .@"fn") .{ .decl = .{ .file = file, .item = m } } else null });
    }
}

/// 按类型列出成员：值为类型时列出声明；实例（含单指针）列出字段与方法；切片与数组有 len
fn typedMembers(r: *Resolver, out: *Collector, tv: TypedValue, from: FileId) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    if (tv.asType()) |t| {
        // 构造的枚举（`@Enum`、union(enum) 的标签枚举）：成员
        switch (ip.key(t)) {
            .reified_type, .union_tag_type => {
                for (try eval.enumMemberNames(r, t)) |name| try out.add(.{ .label = name, .kind = .enum_member });
                return;
            },
            // 错误集（`Error.` 之后）：其中的错误名
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
    // 单指针自动解引用一次：`*[N]T` 的 len、`*S` 的字段与方法、`*[]T` 的 len 与 ptr
    switch (ip.key(t)) {
        .ptr_type => |p| if (p.size == .one) {
            t = p.child;
        },
        else => {},
    }
    switch (ip.key(t)) {
        .ptr_type => |p| {
            // 指向指针的单指针与多元素指针没有成员
            if (p.size == .slice) {
                try out.add(.{ .label = "len", .kind = .field, .detail = "usize" });
                try out.add(.{ .label = "ptr", .kind = .field });
            }
            return;
        },
        .array_type => return out.add(.{ .label = "len", .kind = .field, .detail = "usize" }),
        // 元组、匿名结构体、构造的结构体与 union：字段
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
            .@"fn" => if (same_file or it.flags.is_pub) try out.add(.{ .label = name, .kind = .function, .doc = it.doc, .target = .{ .decl = .{ .file = ns.file, .item = m } } }),
            // 函数的别名（`pub const isPowerPC = isPowerpc;`）同样可以作为方法调用，选中时给出所指函数的签名
            .@"const" => if (same_file or it.flags.is_pub) {
                const ctv = try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = ns.file, .item = it.ast_id }, .inst = queries.instOfType(ip, t) });
                if (ip.key(ctv.ty) == .fn_type) try out.add(.{ .label = name, .kind = .function, .doc = it.doc, .target = try fnTarget(r, ctv) });
            },
            else => {},
        }
    }
}

/// `.` 之后：期望类型（`?T` 取 `T`）的枚举成员、union 的字段，以及可以作为 decl literal 的声明
/// （类型为 `T` 的常量、返回 `T` 或 `!T` 的函数；类型推导不出时也列出）
fn expectedMembers(r: *Resolver, out: *Collector, ty: Index, from: FileId) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    // 与编译器一致，结果类型去掉 error union 与 optional（`fn f() !Color { return .red; }`）
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
                try out.add(.{ .label = name, .kind = if (is_fn) .function else .constant, .doc = it.doc, .target = if (is_fn) .{ .decl = .{ .file = ns.file, .item = m } } else null });
            },
            else => {},
        }
    }
}

/// 声明能否作为类型 `t` 的 decl literal：常量的类型为 `t`，函数返回 `t` 或 `!t`；类型未知时视为可以
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

/// 函数值所指的函数声明
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

/// 光标是否在注释中，或在字符串、字符字面量之内（光标前一个字符所在的 token）
fn commentOrString(r: *Resolver, file: FileId, offset: u32) resolve.Error!enum { none, comment, string } {
    if (offset == 0) return .none;
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const t = root.tokenAtOffset(offset - 1) orelse return .none;
    return switch (t.kind) {
        .line_comment, .doc_comment, .container_doc_comment => .comment,
        // 光标在闭合的引号之后时已在字面量之外
        .string_literal, .char_literal => if (offset < t.offset + t.text.len) .string else .none,
        .identifier => if (std.mem.startsWith(u8, t.text, "@\"") and offset < t.offset + t.text.len) .string else .none,
        .multiline_string_literal_line => .string,
        // 未闭合的字符串
        .invalid => if (t.text.len > 0 and (t.text[0] == '"' or t.text[0] == '\'' or std.mem.startsWith(u8, t.text, "@\""))) .string else .none,
        else => .none,
    };
}

/// `error.` 之后的错误名：期望类型为错误集（或 error union）时列出它的成员，否则列出本文件中出现的
/// 错误名（错误集定义与 `error.X`，光标处的这个除外：未写完的 `error.` 会接上下一行的名字）
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

/// 光标在 `@` 或 `@name` 中时 `@` 的位置（不含 `@"..."` 形式的标识符）
fn builtinStart(text: []const u8, offset: u32) ?u32 {
    var i = offset;
    while (i > 0 and isIdentChar(text[i - 1])) i -= 1;
    if (i == 0 or text[i - 1] != '@') return null;
    return i - 1;
}

/// 光标在 `@import("` 的字符串中时字符串内容的起始位置（字符串可以尚未闭合）
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

/// 光标在 `break :` / `continue :` 之后的标签位置时标签的起始位置
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

/// `@import("...` 中的模块名（std、builtin、root、所属各模块 import 的模块）与相对路径下的
/// `.zig` / `.zon` 文件、子目录。补全项为从字符串开头起的完整路径
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

/// 以枚举字面量 `e` 为元素（没有字段名）的初始化表达式
fn initOf(b: *const Body, e: Body.ExprId) ?Body.ExprId {
    for (b.exprs, 0..) |x, i| switch (x) {
        .init => |init| for (init.fields) |f| if (f.name == null and f.value == e) return @fromBackingInt(@as(u32, @intCast(i))),
        else => {},
    };
    return null;
}

/// 初始化类型（`?T` 取 `T`）中尚未赋值的字段
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

/// `ns.` 之后的成员；同一文件中可以访问非 pub 声明
fn members(r: *Resolver, out: *Collector, ns: Namespace, same_file: bool) resolve.Error!void {
    const tree = try r.itemTree(ns.file);
    if (ns.container >= tree.containers.len) return;
    try decls(out, ns.file, tree, ns.container, same_file);
    const kind = tree.containers[ns.container].kind;
    // 同一文件中的枚举成员（其他文件的由 `decls` 给出）；带标签的 union 在类型上访问字段得到字段的标签
    // （`Value.null_val`），可以转换为 union
    const fields = (same_file and kind == .@"enum") or
        (kind == .@"union" and try eval.unionTag(r, try queries.containerType(r, ns, null)) != null);
    if (!fields) return;
    for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        if (it.kind == .field) if (it.name) |name| try out.add(.{ .label = name, .kind = .enum_member, .doc = it.doc });
    }
}
