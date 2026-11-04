//! Naming conventions: following the Names section of the Zig 0.17 style guide, the style of a
//! name is determined by what the declaration actually represents, not by the `fn` / `const` /
//! `var` keyword:
//! - Types and type aliases: TitleCase
//! - Callables that return `type` (functions and their aliases): TitleCase
//! - Other callables (functions, function aliases, function pointers): camelCase
//! - Namespaces (files without top-level fields): snake_case
//! - Other values: snake_case
//!
//! Fields and enum members are classified the same way, by the type of the field. A verdict is
//! given only when it can be determined reliably; the following are skipped: types that are
//! unknown or depend on the generic instance (abstract type parameters), structs without fields
//! (whether one is a namespace or a zero-sized type to be instantiated depends on intent), fields
//! holding types and optional function pointers (conventions vary), extern / export declarations
//! and extern containers (names follow the external ABI), aliases re-exported under the same name
//! (`const X = c.X;`), and names whose word split is ambiguous (see `split`).
//! Only inference results of the abstract instance are used; the conclusion for one particular
//! instance at a call site does not stand in for the rule on the source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const database = @import("../database.zig");
const Db = database.Db;
const hir = database.hir;
const sema = database.sema;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ItemTree = @import("../syntax/ItemTree.zig");
const ast = @import("../syntax/ast.zig");
const Body = @import("../hir/Body.zig");
const InternPool = @import("../sema/InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const queries = @import("../sema/queries.zig");
const FileId = @import("../base/Vfs.zig").FileId;

/// Link to the description of the rules in the documentation of the user's zig version (the
/// `codeDescription` of diagnostics)
pub fn guideUrl(dialect: database.syntax.SyntaxDialect.Value) []const u8 {
    return switch (dialect) {
        .zig_0_17_0 => "https://ziglang.org/documentation/0.17.0/#Names",
        .zig_0_17_1 => "https://ziglang.org/documentation/0.17.1/#Names",
    };
}

pub const Style = enum {
    title_case,
    camel_case,
    snake_case,

    pub fn label(s: Style) []const u8 {
        return switch (s) {
            .title_case => "TitleCase",
            .camel_case => "camelCase",
            .snake_case => "snake_case",
        };
    }
};

/// The violated rule: corresponds to the entries of the `naming.rules` configuration; the
/// diagnostic code is `naming.<rule>`
pub const Rule = enum {
    /// Types and type aliases
    type,
    /// Callables that return `type`
    type_function,
    /// Other callables
    function,
    /// Namespaces
    namespace,
    /// Other values
    value,
    /// Fields of containers and enum members (style by the type of the field)
    field,

    pub fn code(rule: Rule) []const u8 {
        return switch (rule) {
            inline else => |r| "naming." ++ @tagName(r),
        };
    }

    /// The style that a non-field rule requires
    fn style(rule: Rule) Style {
        return switch (rule) {
            .type, .type_function => .title_case,
            .function => .camel_case,
            .namespace, .value, .field => .snake_case,
        };
    }
};

// ── Word splitting and styles ────────────────────────────────────────

/// The name written in `style`; null when the word split is ambiguous (see `split`)
pub fn convert(a: Allocator, name: []const u8, style: Style) Allocator.Error!?[]const u8 {
    const words = try split(a, name) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |word, i| {
        if (style == .snake_case) {
            if (i > 0) try out.append(a, '_');
            for (word) |c| try out.append(a, std.ascii.toLower(c));
            continue;
        }
        const capitalize = style == .title_case or i > 0;
        for (word, 0..) |c, j| try out.append(a, if (j == 0 and capitalize) std.ascii.toUpper(c) else std.ascii.toLower(c));
    }
    return out.items;
}

/// Splits a name into words: separated by `_`; within the parts, an uppercase letter starts a new
/// word, and digits belong to the preceding word (`readU32Be` is `read`, `U32`, `Be`); a run of
/// uppercase letters is one word (acronyms are treated as ordinary words), except that its last
/// letter joins the next word when followed by a lowercase letter (`XMLParser` is `XML`,
/// `Parser`). Returns null when the split is ambiguous or the spelling may be intentional:
/// - No lowercase letters (`ENOENT`, `MAX_SIZE`, `T`): common when following an existing external
///   convention
/// - Starts or ends with `_`, or contains consecutive `_`
/// - A word split off from a run of uppercase letters has fewer than five letters: where the
///   acronym ends cannot be determined (`URLs`, `HSLuv`, `CIELChuv`, `XYZAtoLMS`)
/// - An uppercase letter after a digit is not followed by a lowercase letter (`Vec3D`: whether it
///   is a unit or a new word cannot be determined)
/// - Does not start with a letter, or contains characters other than letters, digits, and `_`
///   (names that can only be written as `@"..."`)
fn split(a: Allocator, name: []const u8) Allocator.Error!?[]const []const u8 {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return null;
    var has_lower = false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
        if (std.ascii.isLower(c)) has_lower = true;
    }
    if (!has_lower) return null;
    if (name[name.len - 1] == '_' or std.mem.indexOf(u8, name, "__") != null) return null;
    var words: std.ArrayList([]const u8) = .empty;
    var chunks = std.mem.splitScalar(u8, name, '_');
    while (chunks.next()) |chunk| {
        var start: usize = 0;
        for (chunk, 0..) |c, i| {
            if (i == 0 or !std.ascii.isUpper(c)) continue;
            const prev = chunk[i - 1];
            const next_lower = i + 1 < chunk.len and std.ascii.isLower(chunk[i + 1]);
            if (std.ascii.isDigit(prev) and !next_lower) return null;
            if (std.ascii.isUpper(prev)) {
                if (!next_lower) continue;
                var lower: usize = 0;
                while (i + 1 + lower < chunk.len and std.ascii.isLower(chunk[i + 1 + lower])) lower += 1;
                if (lower < 4) return null;
            }
            try words.append(a, chunk[start..i]);
            start = i;
        }
        try words.append(a, chunk[start..]);
    }
    return words.items;
}

// ── Classification ───────────────────────────────────────────────────

/// The rule a name violates and the style it should have
pub const Finding = struct {
    /// A local binding in the body of the member; null for the name of the member itself
    binding: ?Body.BindingId,
    rule: Rule,
    style: Style,
};

/// Names that violate the naming conventions among the member itself and the local bindings in its
/// body (parameters, local constants and variables, captures). Depends only on the source and
/// inference results, not on configuration; positions are not stored, so it is not recomputed
/// when the source merely moves.
pub const Query = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = []const Finding;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        var c: Collector = .{ .r = &r };
        try c.collect(key);
        return ctx.db.gpa.dupe(Finding, c.out.items);
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    pub fn bytes(v: Value) usize {
        return v.len * @sizeOf(Finding);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

const Collector = struct {
    r: *Resolver,
    out: std.ArrayList(Finding) = .empty,

    fn collect(c: *Collector, key: hir.OwnerKey) resolve.Error!void {
        const r = c.r;
        const tree = try r.itemTree(key.file);
        const index = for (tree.items, 0..) |it, i| {
            if (it.ast_id == key.item) break i;
        } else return;
        const item = tree.items[index];
        // External symbols: both the name and the parameter names follow the external spelling
        if (item.flags.is_extern or item.flags.is_export) return;
        const ip = r.ctx.db.env.ip;
        const body = try r.ctx.get(hir.ItemBody, key);
        if (item.name) |name| switch (item.kind) {
            .@"fn", .@"const", .@"var" => if (!reexports(body, body.value, name) and !(item.container == 0 and isRootHook(name))) {
                const tv = try r.ctx.get(sema.DeclType, .{ .owner = key });
                if (try category(r, tv)) |rule| try c.check(name, null, rule, rule.style());
            },
            .field => {
                const container = tree.containers[item.container];
                if (container.layout == .@"extern") return;
                if (container.kind == .@"enum") {
                    try c.check(name, null, .field, .snake_case);
                } else {
                    const ty = (try r.ctx.get(sema.DeclType, .{ .owner = key })).ty;
                    // Fields holding types: written in snake_case in the standard library
                    // (`StructField.type`); conventions vary
                    if (ty != .type_type) if (valueCategory(ip, ty)) |rule| try c.check(name, null, .field, rule.style());
                }
            },
            .@"test", .@"comptime", .zon => {},
        };
        if (body.bindings.len == 0) return;
        const res = try r.ctx.get(sema.Infer, .{ .owner = key, .mode = .full });
        if (res.bindings.len != body.bindings.len) return;
        for (body.bindings, res.bindings, 0..) |binding, tv, i| {
            if (binding.range.end <= binding.range.start) continue;
            // A bare `_` introduces no name
            if (binding.range.end - binding.range.start == 1 and std.mem.eql(u8, binding.name, "_")) continue;
            if (reexports(body, binding.init, binding.name)) continue;
            const rule = try category(r, tv) orelse continue;
            try c.check(binding.name, @fromBackingInt(@as(u32, @intCast(i))), rule, rule.style());
        }
    }

    fn check(c: *Collector, name: []const u8, binding: ?Body.BindingId, rule: Rule, style: Style) Allocator.Error!void {
        const converted = try convert(c.r.arena, name, style) orelse return;
        if (std.mem.eql(u8, converted, name)) return;
        try c.out.append(c.r.arena, .{ .binding = binding, .rule = rule, .style = style });
    }
};

/// Declarations that the standard library looks up by name in the root file (`@hasDecl(root,
/// "...")` in Zig 0.17.1): renaming one silently stops the standard library from using it.
/// Checked in every file, as which file is the root of a compilation is not known here.
fn isRootHook(name: []const u8) bool {
    const hooks = [_][]const u8{
        "main",
        "panic",
        "debug",
        "os",
        "std_options",
        "std_options_cwd",
        "std_options_debug_io",
        "std_options_debug_threaded_io",
        "std_options_elf_debug_info_search_paths",
        "std_options_FilePermissions",
        "DllMain",
        "EfiMain",
        "WinMain",
        "WinMainCRTStartup",
        "wWinMain",
        "wWinMainCRTStartup",
    };
    for (hooks) |h| if (std.mem.eql(u8, h, name)) return true;
    return false;
}

/// The initializer accesses a member of the same name (`const SDL_Window = c.SDL_Window;`): the
/// name is determined by the referenced declaration, which is common for bindings that keep
/// external names such as C names; when the referenced declaration violates the conventions, it
/// is reported there
fn reexports(body: *const Body, init: ?Body.ExprId, name: []const u8) bool {
    const e = init orelse return false;
    return switch (body.expr(e)) {
        .field_access => |fa| if (fa.field) |field| std.mem.eql(u8, field, name) else false,
        else => false,
    };
}

/// The rule (other than `field`) for the value of a declaration or local binding (types and
/// comptime values); null when it cannot be determined reliably
fn category(r: *Resolver, tv: TypedValue) resolve.Error!?Rule {
    if (tv.ty == .unknown) return null;
    if (tv.isType()) return typeCategory(r, tv.val orelse return null);
    return valueCategory(r.ctx.db.env.ip, tv.ty);
}

/// A name whose value is the type `t`: a type, or a namespace
fn typeCategory(r: *Resolver, t: Index) resolve.Error!?Rule {
    const ip = r.ctx.db.env.ip;
    const c = switch (ip.key(t)) {
        .unknown => return null,
        .container_type => |c| c,
        else => return .type,
    };
    const ns = try queries.namespaceOfType(r, t) orelse return null;
    const tree = try r.itemTree(ns.file);
    // External ABI layout: names usually follow the external spelling
    if (tree.containers[ns.container].layout == .@"extern") return null;
    var fields: usize = 0;
    for (tree.containerMembers(ns.container)) |m| {
        if (tree.items[m].kind == .field) fields += 1;
    }
    return switch (c.kind) {
        // Files: a type when there are top-level fields, otherwise a namespace
        .file => if (fields > 0) .type else .namespace,
        // Whether a struct without fields is a namespace or a zero-sized type to be instantiated
        // depends on intent
        .@"struct" => if (fields > 0) .type else null,
        .@"enum", .@"union", .@"opaque" => .type,
    };
}

/// A value (not a type) of type `ty`: a callable, or an ordinary value
fn valueCategory(ip: *InternPool, ty: Index) ?Rule {
    // `@compileError` stubs: the declaration never has a value, and it is named after the API
    // it stands for, which callers still use until they reach its message
    if (ty == .noreturn_type) return null;
    return switch (ip.key(ty)) {
        .unknown, .opaque_param => null,
        .fn_type => |f| callable(ip, f.ret),
        .ptr_type => |p| switch (ip.key(p.child)) {
            .fn_type => |f| if (p.size == .one) callable(ip, f.ret) else .value,
            // Pointer to an abstract type: it may be a function pointer in some instances
            .unknown, .opaque_param => null,
            else => .value,
        },
        // Optional function pointers cannot be called directly; the standard library uses both
        // styles
        .optional_type => |child| switch (ip.key(child)) {
            .unknown, .opaque_param, .fn_type => null,
            .ptr_type => |p| switch (ip.key(p.child)) {
                .fn_type, .unknown, .opaque_param => null,
                else => .value,
            },
            else => .value,
        },
        else => .value,
    };
}

/// A callable whose return type is `ret`
fn callable(ip: *InternPool, ret: Index) ?Rule {
    if (ret == .type_type) return .type_function;
    return switch (ip.key(ret)) {
        .unknown => null,
        // `!type`: a type once the error is removed; conventions vary
        .error_union_type => |e| if (e.payload == .type_type or e.payload == .unknown) null else .function,
        else => .function,
    };
}

// ── Results in a file ────────────────────────────────────────────────

/// A name in a file that violates the naming conventions
pub const Located = struct {
    /// Range of the name token (byte offsets)
    start: u32,
    end: u32,
    name: []const u8,
    rule: Rule,
    style: Style,
    /// The name rewritten in the style it should have (unescaped)
    suggestion: []const u8,
    def: Def,
    /// Function declaration (for the wording of the message)
    is_fn: bool,
    /// `pub` declarations and fields: may be used by code outside the workspace
    public: bool,
};

/// Byte range (both ends inclusive)
pub const Span = struct { start: u32, end: u32 };

/// Names in the file that violate the naming conventions, ordered by position; when `span` is not
/// null, only those intersecting it. Names written as `@"..."` are skipped: the escaping is most
/// likely intentional.
pub fn findings(r: *Resolver, file: FileId, span: ?Span) resolve.Error![]const Located {
    const tree = try r.itemTree(file);
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    var out: std.ArrayList(Located) = .empty;
    for (tree.items, 0..) |item, i| {
        const index: u32 = @intCast(i);
        const node = try r.itemNode(file, index) orelse continue;
        if (span) |s| if (node.range().end < s.start or node.range().start > s.end) continue;
        const list = try r.ctx.get(Query, .{ .file = file, .item = item.ast_id });
        for (list) |f| {
            var start: u32 = undefined;
            var end: u32 = undefined;
            var name: []const u8 = undefined;
            var def: Def = undefined;
            if (f.binding) |b| {
                const binding = (try r.body(file, index)).binding(b);
                start = node.offset + binding.range.start;
                end = node.offset + binding.range.end;
                name = binding.name;
                def = .{ .local = .{ .file = file, .item = index, .binding = b } };
            } else {
                const tok = ast.memberName(node, ItemTree.bareFieldNames(tree.containers[item.container].kind)) orelse continue;
                start = tok.offset;
                end = tok.offset + @as(u32, @intCast(tok.text.len));
                name = item.name orelse continue;
                def = .{ .item = .{ .file = file, .item = index } };
            }
            if (span) |s| if (end < s.start or start > s.end) continue;
            if (start >= text.len or text[start] == '@') continue;
            try out.append(r.arena, .{
                .start = start,
                .end = end,
                .name = name,
                .rule = f.rule,
                .style = f.style,
                .suggestion = try convert(r.arena, name, f.style) orelse continue,
                .def = def,
                .is_fn = f.binding == null and item.kind == .@"fn",
                .public = f.binding == null and (item.flags.is_pub or item.kind == .field),
            });
        }
    }
    std.mem.sort(Located, out.items, {}, struct {
        fn lt(_: void, a: Located, b: Located) bool {
            return a.start < b.start;
        }
    }.lt);
    return out.items;
}

/// The message text
pub fn message(a: Allocator, f: Located) Allocator.Error![]const u8 {
    return switch (f.rule) {
        .type => std.fmt.allocPrint(a, "`{s}` is a type and should be TitleCase: `{s}`", .{ f.name, f.suggestion }),
        .type_function => std.fmt.allocPrint(a, "`{s}` returns a type and should be TitleCase: `{s}`", .{ f.name, f.suggestion }),
        .function => std.fmt.allocPrint(a, "`{s}` is {s} and should be camelCase: `{s}`", .{ f.name, if (f.is_fn) "a function" else "callable", f.suggestion }),
        .namespace => std.fmt.allocPrint(a, "`{s}` is a namespace (a file without fields) and should be snake_case: `{s}`", .{ f.name, f.suggestion }),
        .value => std.fmt.allocPrint(a, "`{s}` should be snake_case: `{s}`", .{ f.name, f.suggestion }),
        .field => switch (f.style) {
            .camel_case => std.fmt.allocPrint(a, "field `{s}` holds a function and should be camelCase: `{s}`", .{ f.name, f.suggestion }),
            else => std.fmt.allocPrint(a, "field `{s}` should be {s}: `{s}`", .{ f.name, f.style.label(), f.suggestion }),
        },
    };
}

// ── Configuration matching ───────────────────────────────────────────

/// `*` in `pattern` matches any sequence of characters (including `/`); other characters match
/// literally
pub fn globMatch(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    // The position after the most recent `*` and the position in `s` it corresponded to: on a
    // mismatch, `*` is made to match one more character
    var star: ?usize = null;
    var star_i: usize = 0;
    while (i < s.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p + 1;
            star_i = i;
            p += 1;
        } else if (p < pattern.len and pattern[p] == s[i]) {
            p += 1;
            i += 1;
        } else if (star) |after| {
            p = after;
            star_i += 1;
            i = star_i;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// The comments at the start of the file mark it as generated code (`DO NOT EDIT`, `@generated`,
/// `Code generated by`, etc.): names are determined by the generator and are not checked. Only the
/// consecutive comment lines at the start are examined.
pub fn isGenerated(text: []const u8) bool {
    const markers = [_][]const u8{
        "do not edit",            "@generated",              "code generated", "auto-generated",
        "autogenerated",          "automatically generated", "generated by",   "generated from",
        "this file is generated", "this file was generated",
    };
    var lines = std.mem.splitScalar(u8, text[0..@min(text.len, 4096)], '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n == 30) break;
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (!std.mem.startsWith(u8, t, "//")) break;
        for (markers) |m| if (std.ascii.findIgnoreCase(t, m) != null) return true;
    }
    return false;
}

test {
    _ = @import("naming_test.zig");
}
