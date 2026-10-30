//! Symbol kinds, shared by semantic highlighting and completion (highlighting maps them to token
//! types, completion to `CompletionItemKind`).
//!
//! Determined by the kind of the declaration and the inferred type: a value that is a type is
//! classified by that type as a namespace (a file without top-level fields), struct (including a
//! file with top-level fields), enum or other type (union, opaque, scalars, ...); a value that is a
//! function (or function pointer) is a function; a function in a container other than a namespace
//! whose first parameter is that container or a single-item pointer to it is a method. When the
//! type cannot be inferred, the kind follows the declaration (variable).

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const database = @import("../database.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const Body = @import("../hir/Body.zig");
const InternPool = @import("../sema/InternPool.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const ast = @import("../syntax/ast.zig");

pub const Kind = enum { namespace, @"struct", @"enum", type, function, method, variable, field, enum_member, parameter, type_parameter };

pub const Symbol = struct {
    kind: Kind,
    /// Cannot be modified: `const` declarations, local constants, parameters and captures
    readonly: bool = false,
};

/// The member `item` (an ItemTree index) of `file`
pub fn ofDecl(r: *Resolver, file: FileId, item: u32) resolve.Error!Symbol {
    const tree = try r.itemTree(file);
    const it = tree.items[item];
    const key: database.hir.OwnerKey = .{ .file = file, .item = it.ast_id };
    return switch (it.kind) {
        .@"fn" => .{ .kind = try functionKind(r, key, tree.containers[it.container]) },
        .field => .{ .kind = if (tree.containers[it.container].kind == .@"enum") .enum_member else .field },
        .@"const" => .{ .kind = try ofValue(r, try r.ctx.get(database.sema.DeclType, .{ .owner = key }), .variable), .readonly = true },
        .@"var" => .{ .kind = try ofValue(r, try r.ctx.get(database.sema.DeclType, .{ .owner = key }), .variable) },
        .@"test", .@"comptime", .zon => .{ .kind = .variable },
    };
}

/// `container` is the container that the function `key` is in
pub fn functionKind(r: *Resolver, key: database.hir.OwnerKey, container: ItemTree.Container) resolve.Error!Kind {
    if (container.kind == .file and !(try r.itemTree(key.file)).hasFields(0)) return .function;
    const ip = r.ctx.db.env.ip;
    const tv = try r.ctx.get(database.sema.DeclType, .{ .owner = key });
    const signature = switch (ip.key(tv.ty)) {
        .fn_type => |f| f,
        else => return .function,
    };
    if (signature.params.len == 0) return .function;
    const receiver = switch (ip.key(signature.params[0])) {
        .ptr_type => |p| if (p.size == .one) p.child else return .function,
        else => signature.params[0],
    };
    return switch (ip.key(receiver)) {
        .container_type => |c| if (c.file == key.file and c.ast_id == container.ast_id) .method else .function,
        else => .function,
    };
}

/// Kind of the value `tv`; `fallback` when it is neither a type nor a function
pub fn ofValue(r: *Resolver, tv: InternPool.TypedValue, fallback: Kind) resolve.Error!Kind {
    const ip = r.ctx.db.env.ip;
    if (tv.isType()) {
        const ty = tv.asType() orelse return .type;
        return switch (ip.key(ty)) {
            .container_type => |c| switch (c.kind) {
                .file => if ((try r.itemTree(c.file)).hasFields(0)) .@"struct" else .namespace,
                .@"struct" => .@"struct",
                .@"enum" => .@"enum",
                .@"union", .@"opaque" => .type,
            },
            .reified_type => |c| switch (c.kind) {
                .@"struct" => .@"struct",
                .@"enum" => .@"enum",
                .@"union" => .type,
            },
            .union_tag_type => .@"enum",
            else => .type,
        };
    }
    return switch (ip.key(tv.ty)) {
        .fn_type => .function,
        .ptr_type => |p| if (ip.key(p.child) == .fn_type) .function else fallback,
        else => fallback,
    };
}

/// A local binding (of type `tv`): a parameter whose value is a type is a type parameter
pub fn ofBinding(r: *Resolver, binding: Body.Binding, tv: InternPool.TypedValue) resolve.Error!Symbol {
    if (binding.kind == .param) return .{ .kind = if (tv.isType()) .type_parameter else .parameter, .readonly = true };
    return .{ .kind = try ofValue(r, tv, .variable), .readonly = binding.kind != .local_var };
}

/// A kind determined by the syntax of the declaration alone, the same as the result of classifying
/// by the inferred type (`ofDecl`). Inferring the type of a declaration requires parsing its file
/// and evaluating the initializer expression, and auto-import candidates come from many files, so
/// the kinds the syntax determines are recorded when the index is built.
pub const Form = enum {
    unknown,
    /// A value that is neither a type nor a function
    value,
    /// A type (`.type` of `ofValue`: not a namespace, struct or enum)
    type,
    /// A value of function type
    function,
};

/// Kind of the `const` / `var` declaration `node`:
/// - A value when the type annotation is a primitive type other than `type`, `?T`, `[]T`, `[N]T`
///   or `E!T`, and a function when it is a function type; other annotations (such as pointers or
///   aliases) may be pointers to functions and are not decided by the syntax
/// - A value when initialized with a literal, `true` / `false` / `null` / `undefined`, an enum
///   literal, `error.X`, an init expression (`.{...}`, `S{...}`), a negation, a logical or bitwise
///   not, or a binary operation other than `orelse`, `catch` and `||`
/// - A type when initialized with a primitive type name, type syntax (`?T`, `*T`, `[]T`, `[N]T`,
///   `E!T`, `error{...}`, `fn (...) R`, `anyframe`) or a merge of error sets (`A || B`)
pub fn declForm(node: ast.SyntaxNode) Form {
    const decl = ast.cast(ast.VarDecl, node) orelse return .unknown;
    if (decl.typeExpr()) |annotation| switch (annotation.kind()) {
        .name_ref => switch (primitive(annotation)) {
            .type_name => return .value,
            else => {},
        },
        .optional_type, .slice_type, .array_type, .error_union_type => return .value,
        .fn_proto => return .function,
        else => {},
    };
    const init = decl.initExpr() orelse return .unknown;
    return switch (init.kind()) {
        .literal, .enum_literal, .error_value, .init_expr => .value,
        .prefix_expr => if (init.childToken(.minus) != null or init.childToken(.bang) != null or init.childToken(.tilde) != null) .value else .unknown,
        .name_ref => switch (primitive(init)) {
            .value => .value,
            .type_name, .type_keyword => .type,
            .none => .unknown,
        },
        .optional_type, .ptr_type, .slice_type, .array_type, .error_union_type, .error_set_decl, .fn_proto, .anyframe_type => .type,
        // `||` is used only to merge error sets; the result of `orelse` and `catch` can be a type
        .binary_expr => if (init.childToken(.pipe_pipe) != null)
            .type
        else if (init.childToken(.keyword_orelse) != null or init.childToken(.keyword_catch) != null)
            .unknown
        else
            .value,
        else => .unknown,
    };
}

/// Whether the name reference is a primitive value (`true` and so on), `type`, or another
/// primitive type name; `@"u32"` is not a primitive name
fn primitive(name_ref: ast.SyntaxNode) enum { none, value, type_keyword, type_name } {
    const token = (ast.NameRef{ .syntax = name_ref }).name() orelse return .none;
    const name = token.text;
    if (!std.zig.primitives.isPrimitive(name)) return .none;
    for ([_][]const u8{ "true", "false", "null", "undefined" }) |v| if (std.mem.eql(u8, name, v)) return .value;
    return if (std.mem.eql(u8, name, "type")) .type_keyword else .type_name;
}

const testing = std.testing;

test "kinds known from the syntax agree with the kinds of the declared types" {
    const World = @import("../names/resolve_test.zig").World;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\const S = struct {};
        \\fn f() void {}
        \\const a = 5;
        \\const b = -1;
        \\const c = "s";
        \\const d = .{ 1, 2 };
        \\const e = .red;
        \\const g = true;
        \\const h = u32;
        \\const i = ?u8;
        \\const j = *const S;
        \\const k = []const u8;
        \\const l = [4]u8;
        \\const m = error{A}!u8;
        \\const n = error{A};
        \\const o = fn () void;
        \\const p: usize = 3;
        \\const q: ?*u8 = null;
        \\const r: fn () void = f;
        \\const s = S{};
        \\const t = error.Oops;
        \\const u = !true;
        \\var v: u32 = 0;
        \\const x = S;
        \\const y = n || error{B};
        \\const z = 64 * 1024 + (1 << 2);
        \\const w = @as(?type, null) orelse u8;
        \\
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const tree = try r.itemTree(file);
    for (tree.items, 0..) |it, index| {
        if (it.kind != .@"const" and it.kind != .@"var") continue;
        const item: u32 = @intCast(index);
        const form = declForm((try r.itemNode(file, item)).?);
        const symbol = try ofDecl(&r, file, item);
        // Containers and aliases need evaluation and are not decided by the syntax
        const expected: Form = if (std.mem.eql(u8, it.name.?, "S") or std.mem.eql(u8, it.name.?, "x") or std.mem.eql(u8, it.name.?, "w")) .unknown else switch (symbol.kind) {
            .type => .type,
            .function => .function,
            .variable => .value,
            else => .unknown,
        };
        testing.expectEqual(expected, form) catch |err| {
            std.debug.print("form of `{s}`\n", .{it.name.?});
            return err;
        };
    }
}
