//! `compiler` 诊断来源：把构建结果中的 ErrorBundle 转换为按文件组织的诊断，并与 live 诊断合并。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const live = @import("live.zig");
const Vfs = @import("../base/Vfs.zig");

/// 一次构建中某个文件的编译器诊断
pub const FileResult = struct {
    /// 构建完成时读取的磁盘文本；诊断的字节区间以它为准
    base_text: []const u8,
    items: []const Item,
};

pub const Item = struct {
    start: u32,
    end: u32,
    message: []const u8,
    /// 是否也是 AstGen（`zig ast-check`）错误。缓冲区有未保存修改时，这类错误改由 live 来源提供。
    is_astgen: bool,
    notes: []const Note,
    /// 附在这条错误上的 `@compileLog` 输出（各行，不含末尾换行），发布时接在文案之后；没有时为空。
    /// 与 `message` 分开存放：去重与 AstGen 匹配都按编译器的原始文案进行
    compile_log: []const u8 = "",
};

pub const Note = struct {
    /// 绝对路径
    path: []const u8,
    start: u32,
    end: u32,
    message: []const u8,
};

/// 一次构建的全部结果，连同自身分配在 arena 中。创建后不再修改，按引用计数共享：持有者（项目、单文件编译）
/// 与读取方各持有一份引用。读取方在持有者的锁内取得引用后即可释放锁，结果被新的结果替换时由最后一份引用释放
pub const BuildResult = struct {
    arena: std.heap.ArenaAllocator.State,
    /// 绝对路径 → 结果
    files: std.StringArrayHashMapUnmanaged(FileResult),
    /// 构建时读取的文本：`files` 中各文件，以及附注指向但没有错误的文件（按路径查找）
    texts: std.StringArrayHashMapUnmanaged([]const u8),
    refs: std.atomic.Value(u32) = .init(1),

    pub fn retain(r: *BuildResult) *BuildResult {
        _ = r.refs.fetchAdd(1, .monotonic);
        return r;
    }

    pub fn release(r: *BuildResult, gpa: Allocator) void {
        if (r.refs.fetchSub(1, .acq_rel) != 1) return;
        var arena = r.arena.promote(gpa);
        arena.deinit();
    }
};

/// 文件读取接口：返回文件当前的磁盘文本（失败返回 null）
pub const ReadFn = *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8;

/// 把一组 ErrorBundle 转换为按文件组织的结果。
/// `src_path` 为相对路径时相对于 `build_root`；没有位置信息的错误（如链接错误）挂在 `fallback_path`（通常是 build.zig）的开头。
/// `src_path` 解析后不是绝对路径时（格式不符的错误包，见 `absolute`）按没有位置处理：错误挂在 `fallback_path`
/// 的开头，附注与引用链放在错误的起点。
pub fn collect(
    gpa: Allocator,
    bundles: []const ErrorBundle,
    build_root: []const u8,
    fallback_path: []const u8,
    read_ctx: *anyopaque,
    read: ReadFn,
) Allocator.Error!*BuildResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();

    var lists: std.StringArrayHashMapUnmanaged(std.ArrayList(Item)) = .empty;
    // 去重：多个 compile step 可能报告同一文件的同一错误。值为保留的那条在该文件列表中的下标
    var seen: std.StringHashMapUnmanaged(usize) = .empty;

    for (bundles) |eb| {
        if (eb.errorMessageCount() == 0) continue;
        const log_text = try a.dupe(u8, std.mem.trimEnd(u8, eb.getCompileLogOutput(), "\n"));
        // `@compileLog` 的输出附在 "found compile log statement" 错误上（没有这条错误时附在第一条错误上）
        const log_target: ?ErrorBundle.MessageIndex = if (log_text.len == 0) null else for (eb.getMessages()) |mi| {
            if (std.mem.eql(u8, eb.nullTerminatedString(eb.getErrorMessage(mi).msg), "found compile log statement")) break mi;
        } else eb.getMessages()[0];
        for (eb.getMessages()) |mi| {
            const msg = eb.getErrorMessage(mi);
            const message = eb.nullTerminatedString(msg.msg);
            const compile_log = if (log_target == mi) log_text else "";
            var path: []const u8 = fallback_path;
            var start: u32 = 0;
            var end: u32 = 0;
            if (msg.src_loc != .none) {
                const loc = eb.getSourceLocation(msg.src_loc);
                if (try absolute(a, build_root, eb.nullTerminatedString(loc.src_path))) |p| {
                    path = p;
                    start, end = byteSpan(loc);
                }
            }
            const key = try std.fmt.allocPrint(a, "{s}\x00{d}\x00{d}\x00{s}", .{ path, start, end, message });
            const seen_gop = try seen.getOrPut(a, key);
            if (seen_gop.found_existing) {
                try addCompileLog(a, &lists.getPtr(path).?.items[seen_gop.value_ptr.*], compile_log);
                continue;
            }

            // 附注之后是引用链（reference trace）
            const refs: u32 = if (msg.src_loc != .none) eb.getSourceLocation(msg.src_loc).reference_trace_len else 0;
            const notes = try a.alloc(Note, msg.notes_len + refs);
            for (notes[0..msg.notes_len], eb.getNotes(mi)) |*note, ni| {
                const n = eb.getErrorMessage(ni);
                note.* = .{ .path = path, .start = start, .end = start, .message = try a.dupe(u8, eb.nullTerminatedString(n.msg)) };
                if (n.src_loc != .none) {
                    const nl = eb.getSourceLocation(n.src_loc);
                    if (try absolute(a, build_root, eb.nullTerminatedString(nl.src_path))) |p| {
                        note.path = p;
                        note.start, note.end = byteSpan(nl);
                    }
                }
            }
            if (refs != 0) try referenceTrace(a, eb, msg.src_loc, build_root, path, start, notes[msg.notes_len..]);
            const gop = try lists.getOrPut(a, path);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            seen_gop.value_ptr.* = gop.value_ptr.items.len;
            try gop.value_ptr.append(a, .{ .start = start, .end = end, .message = try a.dupe(u8, message), .is_astgen = false, .notes = notes, .compile_log = compile_log });
        }
    }

    var files: std.StringArrayHashMapUnmanaged(FileResult) = .empty;
    // 附注指向的文件自身没有错误时不在 `files` 中；同样保存构建时的文本，用于平移附注
    var texts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (lists.values()) |items| for (items.items) |item| for (item.notes) |n| {
        if (texts.contains(n.path)) continue;
        const text = read(read_ctx, a, n.path) orelse continue;
        try texts.put(a, n.path, text);
    };
    for (lists.keys(), lists.values()) |path, *items| {
        const text = texts.get(path) orelse blk: {
            const t = read(read_ctx, a, path) orelse "";
            try texts.put(a, path, t);
            break :blk t;
        };
        // 标记 AstGen 错误：在同一份文本上运行 AstGen，按区间与文案匹配
        const mode: live.Mode = if (std.mem.endsWith(u8, path, ".zon")) .zon else .zig;
        const astgen = try live.check(gpa, text, mode);
        defer astgen.destroy(gpa);
        for (items.items) |*item| {
            for (astgen.items) |d| {
                if (d.start == item.start and d.end == item.end and std.mem.eql(u8, d.message, item.message)) item.is_astgen = true;
            }
        }
        try files.put(a, path, .{ .base_text = text, .items = items.items });
    }
    const result = try a.create(BuildResult);
    result.* = .{ .arena = undefined, .files = files, .texts = texts };
    // arena 的状态在最后一次分配之后取
    result.arena = arena_state.state;
    return result;
}

/// 把源位置 `src_loc` 之后的引用链转换为附注，文案与 `zig build` 的输出一致。有位置的引用指向引用处；
/// 末尾的隐藏标记没有位置，与没有位置的附注一样放在错误的起点（`path` 中的 `start`）
fn referenceTrace(a: Allocator, eb: ErrorBundle, src_loc: ErrorBundle.SourceLocationIndex, build_root: []const u8, path: []const u8, start: u32, out: []Note) Allocator.Error!void {
    // ErrorBundle 没有公开读取引用链的接口：按其布局从 `extra` 中读取。`SourceLocation` 之后依次是各个
    // `ReferenceTrace`，每个按字段顺序存放 `decl_name` 与 `src_loc`
    const first = @backingInt(src_loc) + @typeInfo(ErrorBundle.SourceLocation).@"struct".field_names.len;
    const stride = @typeInfo(ErrorBundle.ReferenceTrace).@"struct".field_names.len;
    for (out, 0..) |*note, k| {
        const at = first + k * stride;
        const decl_name: ErrorBundle.String = eb.extra[at];
        const ref_loc: ErrorBundle.SourceLocationIndex = @fromBackingInt(eb.extra[at + 1]);
        note.* = .{ .path = path, .start = start, .end = start, .message = "" };
        if (ref_loc != .none) {
            const rl = eb.getSourceLocation(ref_loc);
            if (try absolute(a, build_root, eb.nullTerminatedString(rl.src_path))) |p| {
                note.path = p;
                note.start, note.end = byteSpan(rl);
            }
            note.message = try std.fmt.allocPrint(a, "referenced by: {s}", .{eb.nullTerminatedString(decl_name)});
        } else if (decl_name != 0) {
            // 隐藏标记：`decl_name` 为隐藏的引用数
            note.message = try std.fmt.allocPrint(a, "{d} reference(s) hidden; use '-freference-trace={d}' to see all references", .{ decl_name, decl_name + out.len - 1 });
        } else {
            note.message = "remaining reference traces hidden; use '-freference-trace' to see all reference traces";
        }
    }
}

/// 重复的错误只保留一条时，被丢弃的那条带有的 compile log 并到保留的那条上（相同的只保留一份）
fn addCompileLog(a: Allocator, item: *Item, compile_log: []const u8) Allocator.Error!void {
    if (compile_log.len == 0 or std.mem.eql(u8, item.compile_log, compile_log)) return;
    item.compile_log = if (item.compile_log.len == 0) compile_log else try std.mem.join(a, "\n", &.{ item.compile_log, compile_log });
}

/// 源位置的字节区间。数值来自子进程回传的错误包，不受校验：终点在起点之前时改为起点处的空区间，
/// 发布的 Range 不会反向
fn byteSpan(loc: ErrorBundle.SourceLocation) [2]u32 {
    return .{ loc.span_start, @max(loc.span_start, loc.span_end) };
}

/// `path` 相对于 `base` 的绝对路径。结果作为文件驻留到 Vfs，必须是绝对路径；`path` 来自子进程回传的错误包，
/// 内容不受校验，解析后不是绝对路径时返回 null（例如格式不符时路径下标指向源码行中间的 `x: u32 = 1;`，在
/// Windows 上它是另一驱动器的相对路径）
fn absolute(a: Allocator, base: []const u8, path: []const u8) Allocator.Error!?[]const u8 {
    return Vfs.resolve(.native, a, base, path);
}

/// 合并同一文件在多次编译中的结果（包含它的各个项目的构建，单文件模式下 import 它的各个根文件的编译）。`results` 按编译完成的
/// 先后从新到旧排列，以最新一次读取的文本为准：文本相同的结果直接并入；文本不同的（两次编译之间文件被修改）
/// 只并入非 AstGen 错误，按文本差异平移，落在修改区域内的丢弃，与 `merge` 处理未保存修改的方式相同。
/// 区间与文案相同的错误只保留一条（compile log 并到保留的那条上）
pub fn combine(arena: Allocator, results: []const *const FileResult) Allocator.Error!FileResult {
    const base = results[0].base_text;
    var items: std.ArrayList(Item) = .empty;
    for (results) |r| {
        const edits: []const Edit = if (std.mem.eql(u8, r.base_text, base)) &.{} else try diffEdits(arena, r.base_text, base);
        next: for (r.items) |item| {
            var moved = item;
            if (edits.len != 0) {
                if (item.is_astgen) continue;
                const span = remap(edits, item.start, item.end) orelse continue;
                moved.start = span[0];
                moved.end = span[1];
            }
            for (items.items) |*x| {
                if (x.start == moved.start and x.end == moved.end and std.mem.eql(u8, x.message, moved.message)) {
                    try addCompileLog(arena, x, moved.compile_log);
                    continue :next;
                }
            }
            try items.append(arena, moved);
        }
    }
    return .{ .base_text = base, .items = items.items };
}

// ── 合并 ──────────────────────────────────────────────────────────

pub const MergeInput = struct {
    /// 当前缓冲区文本
    text: []const u8,
    lines: offsets.LineIndex,
    encoding: offsets.Encoding,
    uri: []const u8,
    /// live 诊断；文件不在编译集合中时为 null
    live: ?*const live.Result,
    /// 最近一次构建中本文件的编译器诊断
    compiler: ?*const FileResult,
    /// 附注位于其他文件时，用于计算其位置与 URI
    other_file: OtherFileFn,
    other_ctx: *anyopaque,
};

pub const OtherFile = struct { uri: []const u8, text: []const u8, base_text: ?[]const u8 = null };

/// 返回其他文件的 URI 与文本（用于附注位置）；文件不可读时返回 null
pub const OtherFileFn = *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8) ?OtherFile;

pub fn merge(arena: Allocator, in: MergeInput) Allocator.Error![]const types.Diagnostic {
    var out: std.ArrayList(types.Diagnostic) = .empty;
    if (in.compiler) |c| {
        if (std.mem.eql(u8, c.base_text, in.text)) {
            // 缓冲区与构建时一致：编译器诊断已包含 AstGen 错误
            for (c.items) |item| try out.append(arena, try compilerDiagnostic(arena, in, item, item.start, item.end));
            return out.items;
        }
    }
    if (in.live) |l| {
        for (l.items) |d| try out.append(arena, try liveDiagnostic(arena, in, d));
    }
    if (in.compiler) |c| {
        // 有未保存修改：编译器的非 AstGen 错误按文本差异平移，落在修改区域内的隐藏
        const edits = try diffEdits(arena, c.base_text, in.text);
        for (c.items) |item| {
            if (item.is_astgen) continue;
            const span = remap(edits, item.start, item.end) orelse continue;
            try out.append(arena, try compilerDiagnostic(arena, in, item, span[0], span[1]));
        }
    }
    return out.items;
}

/// 新旧文本的差异区间：旧文本 [start, old_end) 被替换为新文本 [start, new_end)
const Edit = struct { start: u32, old_end: u32, new_end: u32 };

const Line = struct { start: u32, end: u32 };

/// 行级锚点：两侧都唯一且内容相同的行
const Anchor = struct { old: usize, new: usize };

/// 按行比较新旧文本，返回按位置排序、互不相交的替换区间。两侧都唯一的相同行作为锚点，其最长递增子序列
/// 之间的行整体视为修改区域。行粒度是保守的：修改一行会隐藏该行上的诊断，不会牵连未修改的行
fn diffEdits(a: Allocator, old: []const u8, new: []const u8) Allocator.Error![]const Edit {
    if (std.mem.eql(u8, old, new)) return &.{};
    const old_lines = try splitLines(a, old);
    const new_lines = try splitLines(a, new);
    var old_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (old_lines) |l| {
        const gop = try old_counts.getOrPut(a, old[l.start..l.end]);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var new_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (new_lines) |l| {
        const gop = try new_counts.getOrPut(a, new[l.start..l.end]);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var old_unique: std.StringHashMapUnmanaged(usize) = .empty;
    for (old_lines, 0..) |l, i| {
        const line = old[l.start..l.end];
        if (old_counts.get(line).? == 1) try old_unique.put(a, line, i);
    }
    var pairs: std.ArrayList(Anchor) = .empty;
    for (new_lines, 0..) |l, i| {
        const line = new[l.start..l.end];
        if (new_counts.get(line).? != 1) continue;
        const oi = old_unique.get(line) orelse continue;
        try pairs.append(a, .{ .old = oi, .new = i });
    }
    const anchors = try longestIncreasing(a, pairs.items);
    var edits: std.ArrayList(Edit) = .empty;
    var oi: usize = 0;
    var ni: usize = 0;
    for (anchors) |an| {
        try addEdit(a, &edits, old, new, old_lines, new_lines, oi, an.old, ni, an.new);
        oi = an.old + 1;
        ni = an.new + 1;
    }
    try addEdit(a, &edits, old, new, old_lines, new_lines, oi, old_lines.len, ni, new_lines.len);
    return edits.items;
}

fn splitLines(a: Allocator, text: []const u8) Allocator.Error![]const Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = if (nl) |i| i + 1 else text.len;
        try lines.append(a, .{ .start = @intCast(start), .end = @intCast(end) });
        start = end;
    }
    return lines.items;
}

fn lineOffset(lines: []const Line, text: []const u8, i: usize) u32 {
    return @intCast(if (i < lines.len) lines[i].start else text.len);
}

fn addEdit(
    a: Allocator,
    edits: *std.ArrayList(Edit),
    old: []const u8,
    new: []const u8,
    old_lines: []const Line,
    new_lines: []const Line,
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
) Allocator.Error!void {
    const os = lineOffset(old_lines, old, old_start);
    const oe = lineOffset(old_lines, old, old_end);
    const ns = lineOffset(new_lines, new, new_start);
    const ne = lineOffset(new_lines, new, new_end);
    if (os == oe and ns == ne) return;
    try edits.append(a, .{ .start = os, .old_end = oe, .new_end = ne });
}

/// `pairs` 按 `new` 递增；返回 `old` 严格递增的最长子序列
fn longestIncreasing(a: Allocator, pairs: []const Anchor) Allocator.Error![]const Anchor {
    if (pairs.len == 0) return &.{};
    const tails = try a.alloc(usize, pairs.len);
    const prev = try a.alloc(?usize, pairs.len);
    var len: usize = 0;
    for (pairs, 0..) |p, i| {
        var lo: usize = 0;
        var hi: usize = len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (pairs[tails[mid]].old < p.old) lo = mid + 1 else hi = mid;
        }
        prev[i] = if (lo > 0) tails[lo - 1] else null;
        tails[lo] = i;
        if (lo == len) len += 1;
    }
    const out = try a.alloc(Anchor, len);
    var k: ?usize = if (len > 0) tails[len - 1] else null;
    var i: usize = len;
    while (k) |x| : (k = prev[x]) {
        i -= 1;
        out[i] = pairs[x];
    }
    return out;
}

/// 区间完全在修改区域之前不变，完全在之后按长度差平移，与任一修改区域相交返回 null。
/// 编译器给出的区间不一定合法（终点在起点之前、远超出文本）：平移后超出 u32 的同样返回 null
fn remap(edits: []const Edit, start: u32, end: u32) ?[2]u32 {
    var delta: i64 = 0;
    for (edits) |e| {
        if (end <= e.start) break;
        if (start < e.old_end) return null;
        delta += @as(i64, e.new_end) - @as(i64, e.old_end);
    }
    const shifted_start = std.math.cast(u32, @as(i64, start) + delta) orelse return null;
    const shifted_end = std.math.cast(u32, @as(i64, end) + delta) orelse return null;
    return .{ shifted_start, shifted_end };
}

// 文案复制到 `arena`：live 结果属于 `AstCheck` 的 memo，编译结果属于工作区（新的构建结果到达时释放），
// 发布在读事务结束、工作区的锁释放之后才序列化，期间两者都可能被释放
fn liveDiagnostic(arena: Allocator, in: MergeInput, d: live.Diagnostic) Allocator.Error!types.Diagnostic {
    const related = try arena.alloc(types.DiagnosticRelatedInformation, d.notes.len);
    for (d.notes, related) |n, *r| r.* = .{
        .location = .{ .uri = in.uri, .range = in.lines.range(n.start, n.end, in.encoding) },
        .message = try arena.dupe(u8, n.message),
    };
    return .{
        .range = in.lines.range(d.start, d.end, in.encoding),
        .severity = .Error,
        .source = "zig ast-check",
        .message = .{ .string = try arena.dupe(u8, d.message) },
        .relatedInformation = if (related.len == 0) null else related,
    };
}

fn compilerDiagnostic(arena: Allocator, in: MergeInput, item: Item, start: u32, end: u32) Allocator.Error!types.Diagnostic {
    var related: std.ArrayList(types.DiagnosticRelatedInformation) = .empty;
    for (item.notes) |n| {
        const other = in.other_file(in.other_ctx, arena, n.path) orelse continue;
        const lines = try offsets.LineIndex.init(arena, other.text);
        // 附注文件在构建后也有未保存修改：按该文件自己的差异平移
        var note_start = n.start;
        var note_end = n.end;
        if (other.base_text) |base| if (!std.mem.eql(u8, base, other.text)) {
            const edits = try diffEdits(arena, base, other.text);
            const span = remap(edits, n.start, n.end) orelse continue;
            note_start = span[0];
            note_end = span[1];
        };
        try related.append(arena, .{
            .location = .{ .uri = other.uri, .range = lines.range(note_start, note_end, in.encoding) },
            .message = try arena.dupe(u8, n.message),
        });
    }
    const message = if (item.compile_log.len == 0)
        try arena.dupe(u8, item.message)
    else
        try std.fmt.allocPrint(arena, "{s}\n\nCompile Log Output:\n{s}", .{ item.message, item.compile_log });
    return .{
        .range = in.lines.range(start, end, in.encoding),
        .severity = .Error,
        .source = "zig",
        .message = .{ .string = message },
        .relatedInformation = if (related.items.len == 0) null else related.items,
    };
}

test {
    _ = @import("compiler_test.zig");
}
