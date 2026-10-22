//! 命名约定：按 Zig 0.17.0 风格指南的 Names 一节，由声明实际表示的东西决定名字的写法，不按 `fn` / `const` /
//! `var` 关键字分类：
//! - 类型与类型别名：TitleCase
//! - 返回 `type` 的可调用对象（函数及其别名）：TitleCase
//! - 其他可调用对象（函数、函数别名、函数指针）：camelCase
//! - 命名空间（没有顶层字段的文件）：snake_case
//! - 其他值：snake_case
//!
//! 字段与枚举成员按字段的类型同样分类。只在能可靠判断时给出结论，以下情况跳过：类型未知或取决于泛型实例
//! （抽象的类型参数）、没有字段的结构体（是命名空间还是要实例化的零大小类型取决于意图）、持有类型的字段与可选的
//! 函数指针（惯例不一）、extern / export 声明与 extern 容器（名字沿用外部 ABI）、以同名重新导出的别名
//! （`const X = c.X;`）、分词不明确的名字（见 `split`）。
//! 只用抽象实例的推导结果，不以调用点的某个实例的结论代替源码的规则。

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

/// 规则说明的链接（诊断的 `codeDescription`）
pub const guide_url = "https://ziglang.org/documentation/0.17.0/#Names";

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

/// 违反的规则：对应配置 `naming.rules` 的各项，诊断的 code 为 `naming.<规则>`
pub const Rule = enum {
    /// 类型与类型别名
    type,
    /// 返回 `type` 的可调用对象
    type_function,
    /// 其他可调用对象
    function,
    /// 命名空间
    namespace,
    /// 其他值
    value,
    /// 容器的字段与枚举成员（写法按字段的类型）
    field,

    pub fn code(rule: Rule) []const u8 {
        return switch (rule) {
            inline else => |r| "naming." ++ @tagName(r),
        };
    }

    /// 非字段的规则要求的写法
    fn style(rule: Rule) Style {
        return switch (rule) {
            .type, .type_function => .title_case,
            .function => .camel_case,
            .namespace, .value, .field => .snake_case,
        };
    }
};

// ── 分词与写法 ───────────────────────────────────────────────────────

/// 名字按 `style` 的写法；分词不明确时为 null（见 `split`）
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

/// 名字分成单词：以 `_` 分隔，其间大写字母开始新的单词，数字归入前一个单词（`readU32Be` 为 `read`、`U32`、`Be`）；
/// 连续的大写字母是一个单词（缩写也按普通单词处理），其中最后一个后面跟着小写字母时归入下一个单词
/// （`XMLParser` 为 `XML`、`Parser`）。以下情况分词不明确或可能是有意的写法，返回 null：
/// - 没有小写字母（`ENOENT`、`MAX_SIZE`、`T`）：常见于沿用外部的既有惯例
/// - 以 `_` 开头或结尾，或含连续的 `_`
/// - 从连续的大写字母中分出的单词不到五个字母：缩写在哪里结束无法判断（`URLs`、`HSLuv`、`CIELChuv`、`XYZAtoLMS`）
/// - 数字之后的大写字母后面没有小写字母（`Vec3D`：是单位还是新的单词无法判断）
/// - 不以字母开头，或含字母、数字与 `_` 以外的字符（只能以 `@"..."` 写出的名字）
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

// ── 分类 ─────────────────────────────────────────────────────────────

/// 一个名字不符合的规则与应有的写法
pub const Finding = struct {
    /// 成员体内的局部绑定；null 为成员自身的名字
    binding: ?Body.BindingId,
    rule: Rule,
    style: Style,
};

/// 成员自身与其体内的局部绑定（参数、局部常量与变量、捕获）中不符合命名约定的名字。只取决于源码与推导结果，
/// 与配置无关；不保存位置，只移动源码时不重算
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
        // 外部符号：名字与参数名都沿用外部的写法
        if (item.flags.is_extern or item.flags.is_export) return;
        const ip = r.ctx.db.env.ip;
        const body = try r.ctx.get(hir.ItemBody, key);
        if (item.name) |name| switch (item.kind) {
            .@"fn", .@"const", .@"var" => if (!reexports(body, body.value, name)) {
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
                    // 持有类型的字段：标准库中写作 snake_case（`StructField.type`），惯例不一
                    if (ty != .type_type) if (valueCategory(ip, ty)) |rule| try c.check(name, null, .field, rule.style());
                }
            },
            .@"test", .@"comptime" => {},
        };
        if (body.bindings.len == 0) return;
        const res = try r.ctx.get(sema.Infer, .{ .owner = key, .mode = .full });
        if (res.bindings.len != body.bindings.len) return;
        for (body.bindings, res.bindings, 0..) |binding, tv, i| {
            if (binding.range.end <= binding.range.start) continue;
            // 裸 `_` 不引入名字
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

/// 初始化表达式是对同名成员的访问（`const SDL_Window = c.SDL_Window;`）：名字由被引用的声明决定，常见于沿用
/// C 等外部名字的绑定，被引用的声明不符合约定时在那里提示
fn reexports(body: *const Body, init: ?Body.ExprId, name: []const u8) bool {
    const e = init orelse return false;
    return switch (body.expr(e)) {
        .field_access => |fa| if (fa.field) |field| std.mem.eql(u8, field, name) else false,
        else => false,
    };
}

/// 声明或局部绑定的值（类型与 comptime 值）对应的规则（不含 `field`）；无法可靠判断时为 null
fn category(r: *Resolver, tv: TypedValue) resolve.Error!?Rule {
    if (tv.ty == .unknown) return null;
    if (tv.isType()) return typeCategory(r, tv.val orelse return null);
    return valueCategory(r.ctx.db.env.ip, tv.ty);
}

/// 值为类型 `t` 的名字：类型，或者命名空间
fn typeCategory(r: *Resolver, t: Index) resolve.Error!?Rule {
    const ip = r.ctx.db.env.ip;
    const c = switch (ip.key(t)) {
        .unknown => return null,
        .container_type => |c| c,
        else => return .type,
    };
    const ns = try queries.namespaceOfType(r, t) orelse return null;
    const tree = try r.itemTree(ns.file);
    // 外部 ABI 的布局：名字通常沿用外部的写法
    if (tree.containers[ns.container].layout == .@"extern") return null;
    var fields: usize = 0;
    for (tree.containerMembers(ns.container)) |m| {
        if (tree.items[m].kind == .field) fields += 1;
    }
    return switch (c.kind) {
        // 文件：有顶层字段的是类型，否则是命名空间
        .file => if (fields > 0) .type else .namespace,
        // 没有字段的结构体是命名空间还是要实例化的零大小类型，取决于意图
        .@"struct" => if (fields > 0) .type else null,
        .@"enum", .@"union", .@"opaque" => .type,
    };
}

/// 类型为 `ty` 的值（不是类型）：可调用对象，或者普通的值
fn valueCategory(ip: *InternPool, ty: Index) ?Rule {
    return switch (ip.key(ty)) {
        .unknown, .opaque_param => null,
        .fn_type => |f| callable(ip, f.ret),
        .ptr_type => |p| switch (ip.key(p.child)) {
            .fn_type => |f| if (p.size == .one) callable(ip, f.ret) else .value,
            // 指向抽象类型的指针：在一些实例中可能是函数指针
            .unknown, .opaque_param => null,
            else => .value,
        },
        // 可选的函数指针不能直接调用，标准库中两种写法都有
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

/// 返回类型为 `ret` 的可调用对象
fn callable(ip: *InternPool, ret: Index) ?Rule {
    if (ret == .type_type) return .type_function;
    return switch (ip.key(ret)) {
        .unknown => null,
        // `!type`：去掉错误之后是类型，惯例不一
        .error_union_type => |e| if (e.payload == .type_type or e.payload == .unknown) null else .function,
        else => .function,
    };
}

// ── 文件中的结果 ─────────────────────────────────────────────────────

/// 文件中一个不符合命名约定的名字
pub const Located = struct {
    /// 名字 token 的区间（字节偏移）
    start: u32,
    end: u32,
    name: []const u8,
    rule: Rule,
    style: Style,
    /// 按应有的写法改写的名字（未转义）
    suggestion: []const u8,
    def: Def,
    /// 函数声明（提示的措辞）
    is_fn: bool,
    /// `pub` 声明与字段：可能被工作区之外的代码使用
    public: bool,
};

/// 字节区间（两端都含）
pub const Span = struct { start: u32, end: u32 };

/// 文件中不符合命名约定的名字，按位置排列；`span` 不为 null 时只取与它相交的。以 `@"..."` 写出的名字跳过：
/// 转义多半是有意的写法
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

/// 提示的文案
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

// ── 配置的匹配 ───────────────────────────────────────────────────────

/// `pattern` 中的 `*` 匹配任意字符序列（含 `/`），其余字符按原样匹配
pub fn globMatch(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    // 最近一个 `*` 之后的位置与它当时对应的 `s` 中的位置：失配时让 `*` 多匹配一个字符
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

/// 文件开头的注释标明它是生成的代码（`DO NOT EDIT`、`@generated`、`Code generated by` 等）：名字由生成器决定，
/// 不检查。只看开头连续的注释行
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
