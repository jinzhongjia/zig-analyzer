//! 语料对拍：在一批 Zig 源码上校验自研 CST 解析器。
//!
//! 用法：zig build corpus -- <目录或文件>...
//!
//! 校验项：
//! 1. 无损：语法树文本拼接等于原文
//! 2. 无误报：`std.zig.Ast` 无错误的文件，CST 也必须无错误
//! 3. 结构一致：容器顶层成员的（种类, 名字）序列与 `std.zig.Ast` 一致
//! 4. 健壮性：在多个位置截断文件后解析不崩溃且仍然无损
//! 5. HIR：每个成员都能降级，表达式位置在成员内，名字引用逐一对应源码的标识符（含 asm 输出目标）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("zig_analyzer");
const syntax = za.syntax;
const SyntaxNode = syntax.SyntaxNode;

const Stats = struct {
    files: usize = 0,
    bytes: usize = 0,
    std_errors: usize = 0,
    /// 嵌套过深、跳过与官方解析器对拍的文件
    std_skipped: usize = 0,
    lossless_failures: usize = 0,
    false_errors: usize = 0,
    structure_mismatches: usize = 0,
    truncations: usize = 0,
    reparse_edits: usize = 0,
    reparse_incremental: usize = 0,
    reparse_mismatches: usize = 0,
    reparse_full_ns: u64 = 0,
    reparse_inc_ns: u64 = 0,
    /// 只统计走了局部重解析的编辑
    local_inc_ns: u64 = 0,
    local_full_ns: u64 = 0,
    items: usize = 0,
    item_failures: usize = 0,
    item_tree_ns: u64 = 0,
    hir_exprs: usize = 0,
    hir_failures: usize = 0,
    hir_ns: u64 = 0,
    parse_ns: u64 = 0,
    reported: usize = 0,
};

const max_reports = 20;
/// 设置环境变量 CORPUS_DEBUG 时打印结构差异详情
var debug = false;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: {s} <dir or file>...\n", .{args[0]});
        return 1;
    }

    debug = init.environ_map.get("CORPUS_DEBUG") != null;
    var stats: Stats = .{};
    for (args[1..]) |root| {
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, root, .{ .iterate = true }) catch {
            try checkFile(gpa, io, cwd, root, &stats);
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const path = try std.fs.path.join(gpa, &.{ root, entry.path });
            defer gpa.free(path);
            try checkFile(gpa, io, cwd, path, &stats);
        }
    }

    const mb = @as(f64, @floatFromInt(stats.bytes)) / (1024 * 1024);
    const secs = @as(f64, @floatFromInt(stats.parse_ns)) / std.time.ns_per_s;
    const ns = std.time.ns_per_s;
    std.debug.print(
        \\files: {d} ({d:.1} MB, {d} with std.zig.Ast errors, {d} skipped for depth)
        \\lossless failures: {d}
        \\false errors: {d}
        \\structure mismatches: {d}
        \\truncated parses: {d}, no crashes
        \\CST parse time: {d:.2}s ({d:.1} MB/s)
        \\ItemTree: {d} members, {d} mapping failures, build time {d:.2}s
        \\HIR: {d} exprs, {d} failures, lowering time {d:.2}s
        \\incremental reparse: {d} random edits, {d} block reparses, {d} mismatches with full parse; time incremental {d:.2}s / full {d:.2}s
        \\  block-reparse edits only: incremental {d:.3}s / full parse of same text {d:.3}s ({d:.1}x)
        \\
    , .{
        stats.files,                                         mb,
        stats.std_errors,                                    stats.std_skipped,
        stats.lossless_failures,                             stats.false_errors,
        stats.structure_mismatches,                          stats.truncations,
        secs,                                                mb / secs,
        stats.items,                                         stats.item_failures,
        @as(f64, @floatFromInt(stats.item_tree_ns)) / ns,    stats.hir_exprs,
        stats.hir_failures,                                  @as(f64, @floatFromInt(stats.hir_ns)) / ns,
        stats.reparse_edits,                                 stats.reparse_incremental,
        stats.reparse_mismatches,                            @as(f64, @floatFromInt(stats.reparse_inc_ns)) / ns,
        @as(f64, @floatFromInt(stats.reparse_full_ns)) / ns, @as(f64, @floatFromInt(stats.local_inc_ns)) / ns,
        @as(f64, @floatFromInt(stats.local_full_ns)) / ns,   @as(f64, @floatFromInt(stats.local_full_ns)) / @as(f64, @floatFromInt(@max(stats.local_inc_ns, 1))),
    });
    const failed = stats.lossless_failures + stats.false_errors + stats.structure_mismatches + stats.item_failures + stats.reparse_mismatches + stats.hir_failures;
    return if (failed == 0) 0 else 1;
}

fn report(stats: *Stats, comptime fmt: []const u8, args: anytype) void {
    stats.reported += 1;
    if (stats.reported <= max_reports) std.debug.print(fmt ++ "\n", args);
}

fn checkFile(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, stats: *Stats) !void {
    const source = dir.readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read {s}: {t}\n", .{ path, err });
        return;
    };
    defer gpa.free(source);
    stats.files += 1;
    stats.bytes += source.len;

    const t0 = std.Io.Clock.awake.now(io);
    const parse = try syntax.Parse.create(gpa, source);
    stats.parse_ns += @intCast(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    defer parse.destroy();

    // 1. 无损
    if (!try isLossless(gpa, parse.rootNode(), source)) {
        stats.lossless_failures += 1;
        report(stats, "[lossless failure] {s}", .{path});
    }

    // ItemTree 与 AstIdMap：每个成员都能映射回对应种类的节点
    {
        const t1 = std.Io.Clock.awake.now(io);
        var items = try syntax.ItemTree.build(gpa, parse.rootNode());
        defer items.deinit(gpa);
        var map = try syntax.ItemTree.AstIdMap.build(gpa, &items, parse.rootNode());
        defer map.deinit(gpa);
        stats.item_tree_ns += @intCast(t1.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
        stats.items += items.items.len;
        const ok = map.map.count() == items.items.len + items.containers.len and for (items.items) |item| {
            const node = map.get(item.ast_id) orelse break false;
            const expected_kind: za.syntax.SyntaxKind = switch (item.kind) {
                .@"fn" => .fn_decl,
                .@"const", .@"var" => .var_decl,
                .field => .container_field,
                .@"test" => .test_decl,
                .@"comptime" => .comptime_decl,
            };
            if (node.kind() != expected_kind) break false;
        } else true;
        if (!ok) {
            stats.item_failures += 1;
            report(stats, "[ItemTree mapping failure] {s}", .{path});
        }

        for (items.items) |item| {
            const node = map.get(item.ast_id) orelse continue;
            // enum 成员与 union 中只写名字的字段：名字不是表达式（同 `ItemBody`）
            const container_kind = items.containers[item.container].kind;
            const field_is_name = item.kind == .field and (container_kind == .@"enum" or container_kind == .@"union") and
                (syntax.ast.ContainerField{ .syntax = node }).name() == null;
            const t2 = std.Io.Clock.awake.now(io);
            var body = try za.hir.lower.lower(gpa, node, field_is_name);
            defer body.deinit(gpa);
            stats.hir_ns += @intCast(t2.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
            stats.hir_exprs += body.exprs.len;
            var references: std.AutoHashMapUnmanaged(syntax.TextRange, syntax.SyntaxToken) = .empty;
            defer references.deinit(gpa);
            const name_node = if (field_is_name) (syntax.ast.ContainerField{ .syntax = node }).typeExpr() else null;
            const excluded = if (name_node) |name| if (name.kind() == .name_ref) name.offset else null else null;
            try collectNameRefs(gpa, node, excluded, &references);
            const expected = references.count();
            const in_range = body.exprs.len == body.expr_ranges.len and for (body.expr_ranges) |r| {
                if (r.start > r.end or r.end > node.green.text_len) break false;
            } else true;
            var decoded: std.heap.ArenaAllocator = .init(gpa);
            defer decoded.deinit();
            var names_match = in_range;
            var name_refs: usize = 0;
            if (in_range) for (body.exprs, body.expr_ranges) |expr, range| {
                if (expr != .name_ref) continue;
                name_refs += 1;
                const key: syntax.TextRange = .{ .start = node.offset + range.start, .end = node.offset + range.end };
                const ref = references.fetchRemove(key) orelse {
                    names_match = false;
                    continue;
                };
                if (!std.mem.eql(u8, expr.name_ref, try syntax.ast.identNameAlloc(decoded.allocator(), ref.value.text))) names_match = false;
            };
            if (!names_match or references.count() != 0) {
                stats.hir_failures += 1;
                report(stats, "[HIR failure] {s}: member at {d} (name refs {d} / {d}, unmatched source refs {d})", .{ path, node.offset, name_refs, expected, references.count() });
            }
        }
    }

    // 2. 与 std.zig.Ast 对比（嵌套过深的文件跳过：官方解析器会耗尽栈）
    const source_z = try gpa.dupeSentinel(u8, source, 0);
    defer gpa.free(source_z);
    if (try syntax.nesting.estimate(gpa, source_z, syntax.nesting.inline_depth) > syntax.nesting.inline_depth) {
        stats.std_skipped += 1;
    } else {
        var ast = try std.zig.Ast.parse(gpa, source_z, .{});
        defer ast.deinit(gpa);
        if (ast.errors.len != 0) {
            stats.std_errors += 1;
        } else {
            if (parse.errors.len != 0) {
                stats.false_errors += 1;
                const e = parse.errors[0];
                const loc = lineCol(source, e.offset);
                report(stats, "[false error] {s}:{d}:{d}: {s} ({d} total)", .{ path, loc.line, loc.col, e.message, parse.errors.len });
            }
            // 3. 顶层结构
            if (!try sameStructure(gpa, &ast, parse.rootNode(), source)) {
                stats.structure_mismatches += 1;
                report(stats, "[structure mismatch] {s}", .{path});
            }
        }
    }

    // 5. 增量重解析：在随机位置做随机编辑（单次编辑与连续编辑链），结果必须与全量解析一致
    try checkReparse(gpa, io, path, source, stats);

    // 4. 截断
    const cuts = 8;
    for (1..cuts) |i| {
        const end = source.len * i / cuts;
        const partial = try syntax.Parse.create(gpa, source[0..end]);
        defer partial.destroy();
        stats.truncations += 1;
        if (!try isLossless(gpa, partial.rootNode(), source[0..end])) {
            stats.lossless_failures += 1;
            report(stats, "[truncated lossless failure] {s} @ {d}", .{ path, end });
        }
    }
}

const snippets = [_][]const u8{
    "x",           " ",         "\n",                ";",      "{",   "}",          "(",  ")",   ".", "\"", "//", "const a = 1;", "foo(", "if (a) {", "} else {",
    ".{ .a = 1 }", "error.Foo", "struct { a: u32 }", "\\\\ml", "'c'", "@as(u8, 1)", "=>", "...",
};

fn checkReparse(gpa: Allocator, io: std.Io, path: []const u8, source: []const u8, stats: *Stats) !void {
    if (source.len == 0) return;
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, path));
    const rand = prng.random();

    var chain = try syntax.Parse.create(gpa, source);
    defer chain.destroy();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, source);

    const edits = 12;
    for (0..edits) |_| {
        // 随机编辑：删除 0~8 字节并插入一个片段
        const at = rand.uintLessThan(usize, text.items.len + 1);
        const del = @min(rand.uintLessThan(usize, 9), text.items.len - at);
        const ins = if (rand.boolean()) snippets[rand.uintLessThan(usize, snippets.len)] else "";
        try text.replaceRange(gpa, at, del, ins);

        const t0 = std.Io.Clock.awake.now(io);
        const inc = try syntax.Parse.reparse(gpa, chain, text.items);
        const t1 = std.Io.Clock.awake.now(io);
        const full = try syntax.Parse.create(gpa, text.items);
        const t2 = std.Io.Clock.awake.now(io);
        defer full.destroy();

        stats.reparse_edits += 1;
        if (inc.base != null) {
            stats.reparse_incremental += 1;
            stats.local_inc_ns += @intCast(t0.durationTo(t1).nanoseconds);
            stats.local_full_ns += @intCast(t1.durationTo(t2).nanoseconds);
        }
        stats.reparse_inc_ns += @intCast(t0.durationTo(t1).nanoseconds);
        stats.reparse_full_ns += @intCast(t1.durationTo(t2).nanoseconds);
        if (!inc.sameAs(full)) {
            stats.reparse_mismatches += 1;
            report(stats, "[incremental mismatch] {s}: at {d} deleted {d} bytes and inserted \"{s}\"", .{ path, at, del, ins });
        }
        chain.destroy();
        chain = inc;
    }
}

/// 收集 HIR 中应存在的源码引用；嵌套容器的成员由各自的 owner 检查。
fn collectNameRefs(gpa: Allocator, node: SyntaxNode, excluded: ?u32, references: *std.AutoHashMapUnmanaged(syntax.TextRange, syntax.SyntaxToken)) !void {
    switch (node.kind()) {
        .name_ref => {
            if (excluded == node.offset) return;
            if ((syntax.ast.NameRef{ .syntax = node }).name()) |token| try references.put(gpa, token.range(), token);
            return;
        },
        .container_decl => {
            if ((syntax.ast.ContainerDecl{ .syntax = node }).argExpr()) |arg| try collectNameRefs(gpa, arg, excluded, references);
            return;
        },
        .asm_output => if (node.childToken(.arrow) == null) {
            // 输出的局部变量是直接 token，不是 name_ref 子节点；寄存器标签不算引用。
            var children = node.children();
            var operand = false;
            while (children.next()) |child| if (child == .token) {
                if (child.token.kind == .l_paren) operand = true;
                if (operand and child.token.kind == .identifier) {
                    try references.put(gpa, child.token.range(), child.token);
                    break;
                }
            };
        },
        else => {},
    }
    var children = node.children();
    while (children.nextNode()) |child| try collectNameRefs(gpa, child, excluded, references);
}

fn isLossless(gpa: Allocator, root: SyntaxNode, source: []const u8) !bool {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeText(root, &out.writer);
    return std.mem.eql(u8, out.written(), source);
}

fn writeText(n: SyntaxNode, w: *std.Io.Writer) !void {
    var it = n.children();
    while (it.next()) |e| switch (e) {
        .node => |c| try writeText(c, w),
        .token => |t| try w.writeAll(t.text),
    };
}

fn lineCol(source: []const u8, offset: u32) struct { line: usize, col: usize } {
    const before = source[0..@min(offset, source.len)];
    const line = std.mem.countScalar(u8, before, '\n') + 1;
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0;
    return .{ .line = line, .col = before.len - line_start + 1 };
}

const Member = struct { kind: []const u8, name: []const u8 };

/// 逐个容器比较成员序列。容器以其关键字（struct/enum/...）的偏移标识，文件根用偏移 maxInt。
fn sameStructure(gpa: Allocator, ast: *const std.zig.Ast, root: SyntaxNode, source: []const u8) !bool {
    _ = source;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var expected: std.AutoArrayHashMapUnmanaged(u32, []const Member) = .empty;
    for (0..ast.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@as(u32, @intCast(i)));
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, node) orelse continue;
        const key: u32 = if (i == 0) std.math.maxInt(u32) else ast.tokenStart(container.ast.main_token);
        var members: std.ArrayList(Member) = .empty;
        for (container.ast.members) |decl| try members.append(arena, astMember(ast, decl));
        try expected.put(arena, key, members.items);
    }

    var actual: std.AutoArrayHashMapUnmanaged(u32, []const Member) = .empty;
    try collectCst(arena, root, std.math.maxInt(u32), &actual);

    var same = expected.count() == actual.count();
    for (expected.keys(), expected.values()) |key, exp| {
        const act = actual.get(key) orelse {
            if (debug) std.debug.print("  CST missing container @{d}\n", .{key});
            same = false;
            continue;
        };
        const equal = exp.len == act.len and for (exp, act) |e, a| {
            if (!std.mem.eql(u8, e.kind, a.kind) or !std.mem.eql(u8, e.name, a.name)) break false;
        } else true;
        if (!equal) {
            same = false;
            if (debug) {
                std.debug.print("  container @{d} members differ\n    std:", .{key});
                for (exp) |e| std.debug.print(" {s}:{s}", .{ e.kind, e.name });
                std.debug.print("\n    cst:", .{});
                for (act) |a| std.debug.print(" {s}:{s}", .{ a.kind, a.name });
                std.debug.print("\n", .{});
            }
        }
    }
    if (debug) for (actual.keys()) |key| {
        if (!expected.contains(key)) std.debug.print("  CST extra container @{d}\n", .{key});
    };
    return same;
}

fn astMember(ast: *const std.zig.Ast, decl: std.zig.Ast.Node.Index) Member {
    var buf: [1]std.zig.Ast.Node.Index = undefined;
    return switch (ast.nodeTag(decl)) {
        .test_decl => .{ .kind = "test", .name = "" },
        .@"comptime" => .{ .kind = "comptime", .name = "" },
        else => if (ast.fullFnProto(&buf, if (ast.nodeTag(decl) == .fn_decl) ast.nodeData(decl).node_and_node[0] else decl)) |proto|
            .{ .kind = "fn", .name = if (proto.name_token) |t| ast.tokenSlice(t) else "" }
        else if (ast.fullVarDecl(decl)) |v|
            .{ .kind = "var", .name = ast.tokenSlice(v.ast.mut_token + 1) }
        else if (ast.fullContainerField(decl)) |f|
            .{ .kind = "field", .name = if (f.ast.tuple_like) "" else ast.tokenSlice(f.ast.main_token) }
        else
            .{ .kind = @tagName(ast.nodeTag(decl)), .name = "" },
    };
}

fn collectCst(arena: Allocator, container: SyntaxNode, key: u32, out: *std.AutoArrayHashMapUnmanaged(u32, []const Member)) Allocator.Error!void {
    var members: std.ArrayList(Member) = .empty;
    var it = container.children();
    while (it.nextNode()) |n| {
        const member: ?Member = switch (n.kind()) {
            .test_decl => .{ .kind = "test", .name = "" },
            .comptime_decl => .{ .kind = "comptime", .name = "" },
            .fn_decl => .{ .kind = "fn", .name = if (n.childNode(.fn_proto)) |proto| if (proto.childToken(.identifier)) |t| t.text else "" else "" },
            .var_decl => .{ .kind = "var", .name = if (n.childToken(.identifier)) |t| t.text else "" },
            .container_field => .{ .kind = "field", .name = if (n.childToken(.identifier)) |t| t.text else "" },
            else => null,
        };
        if (member) |m| try members.append(arena, m);
    }
    try out.put(arena, key, members.items);
    try collectNested(arena, container, out);
}

/// 在子树中查找 container_decl（跳过 `node` 本身）
fn collectNested(arena: Allocator, node: SyntaxNode, out: *std.AutoArrayHashMapUnmanaged(u32, []const Member)) Allocator.Error!void {
    var it = node.children();
    while (it.nextNode()) |c| {
        if (c.kind() == .container_decl) {
            var tokens = c.children();
            const kw = while (tokens.next()) |e| switch (e.kind()) {
                .keyword_struct, .keyword_enum, .keyword_union, .keyword_opaque => break e.token,
                else => {},
            } else continue;
            try collectCst(arena, c, kw.offset, out);
        } else {
            try collectNested(arena, c, out);
        }
    }
}
