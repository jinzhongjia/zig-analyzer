//! 符号的种类：语义着色与补全共用（着色映射为 token 类型，补全映射为 `CompletionItemKind`）。
//!
//! 由声明的种类与推导出的类型决定：值为类型的按类型分为命名空间（文件）、结构体、枚举与其他类型（union、opaque、
//! 标量等）；值为函数（或函数指针）的为函数；容器（不是文件）中第一个参数是所在容器或指向它的单指针的函数为方法。
//! 类型求不出时按声明的种类（变量）。

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
    /// 不可修改：`const` 声明、局部常量、参数与捕获
    readonly: bool = false,
};

/// `file` 中的成员 `item`（ItemTree 的下标）
pub fn ofDecl(r: *Resolver, file: FileId, item: u32) resolve.Error!Symbol {
    const tree = try r.itemTree(file);
    const it = tree.items[item];
    const key: database.hir.OwnerKey = .{ .file = file, .item = it.ast_id };
    const ip = r.ctx.db.env.ip;
    return switch (it.kind) {
        .@"fn" => .{ .kind = try functionKind(r, key, tree.containers[it.container]) },
        .field => .{ .kind = if (tree.containers[it.container].kind == .@"enum") .enum_member else .field },
        .@"const" => .{ .kind = ofValue(ip, try r.ctx.get(database.sema.DeclType, .{ .owner = key }), .variable), .readonly = true },
        .@"var" => .{ .kind = ofValue(ip, try r.ctx.get(database.sema.DeclType, .{ .owner = key }), .variable) },
        .@"test", .@"comptime" => .{ .kind = .variable },
    };
}

/// 函数 `key` 所在的容器为 `container`
pub fn functionKind(r: *Resolver, key: database.hir.OwnerKey, container: ItemTree.Container) resolve.Error!Kind {
    if (container.kind == .file) return .function;
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

/// 值 `tv` 的种类：不是类型也不是函数时为 `fallback`
pub fn ofValue(ip: *InternPool, tv: InternPool.TypedValue, fallback: Kind) Kind {
    if (tv.isType()) {
        const ty = tv.asType() orelse return .type;
        return switch (ip.key(ty)) {
            .container_type => |c| switch (c.kind) {
                .file => .namespace,
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

/// 局部绑定（类型为 `tv`）：值为类型的参数为类型参数
pub fn ofBinding(ip: *InternPool, binding: Body.Binding, tv: InternPool.TypedValue) Symbol {
    if (binding.kind == .param) return .{ .kind = if (tv.isType()) .type_parameter else .parameter, .readonly = true };
    return .{ .kind = ofValue(ip, tv, .variable), .readonly = binding.kind != .local_var };
}

/// 只看声明的语法就能确定的种类，与按推导出的类型分类（`ofDecl`）的结果相同。求声明的类型要解析所在的文件、对
/// 初始化表达式求值，自动导入的候选来自许多文件，建索引时按语法记下能确定的种类
pub const Form = enum {
    unknown,
    /// 不是类型也不是函数的值
    value,
    /// 类型（`ofValue` 的 `.type`：不是命名空间、结构体或枚举）
    type,
    /// 函数类型的值
    function,
};

/// `const` / `var` 声明 `node` 的种类：
/// - 类型标注为 `type` 以外的原始类型、`?T`、`[]T`、`[N]T`、`E!T` 时为值，为函数类型时为函数；其他标注（如指针、
///   别名）可能是指向函数的指针，不由语法判断
/// - 初始化为字面量、`true` / `false` / `null` / `undefined`、枚举字面量、`error.X`、初始化表达式（`.{...}`、
///   `S{...}`）、取负、取反与 `orelse`、`catch`、`||` 以外的二元运算时为值
/// - 初始化为原始类型名、类型语法（`?T`、`*T`、`[]T`、`[N]T`、`E!T`、`error{...}`、`fn (...) R`、`anyframe`）或错误集的
///   合并（`A || B`）时为类型
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
        // `||` 只用于合并错误集；`orelse` 与 `catch` 的结果可以是类型
        .binary_expr => if (init.childToken(.pipe_pipe) != null)
            .type
        else if (init.childToken(.keyword_orelse) != null or init.childToken(.keyword_catch) != null)
            .unknown
        else
            .value,
        else => .unknown,
    };
}

/// 名字引用是否为原始的值（`true` 等）、`type`、其他原始类型名；`@"u32"` 不是原始名字
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
        // 容器与别名要求值，不由语法判断
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
