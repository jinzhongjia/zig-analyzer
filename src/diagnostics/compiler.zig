//! `compiler` 诊断来源：把构建结果中的 ErrorBundle 转换为按文件组织的诊断，并与 live 诊断合并（设计 §11.3、§11.5）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const live = @import("live.zig");

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
};

pub const Note = struct {
    /// 绝对路径
    path: []const u8,
    start: u32,
    end: u32,
    message: []const u8,
};

/// 一次构建的全部结果
pub const BuildResult = struct {
    arena: std.heap.ArenaAllocator.State,
    /// 绝对路径 → 结果
    files: std.StringArrayHashMapUnmanaged(FileResult),

    pub fn deinit(r: *BuildResult, gpa: Allocator) void {
        var arena = r.arena.promote(gpa);
        arena.deinit();
        r.* = undefined;
    }
};

/// 文件读取接口：返回文件当前的磁盘文本（失败返回 null）
pub const ReadFn = *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8;

/// 把一组 ErrorBundle 转换为按文件组织的结果。
/// `src_path` 为相对路径时相对于 `build_root`；没有位置信息的错误（如链接错误）挂在 `fallback_path`（通常是 build.zig）的开头。
pub fn collect(
    gpa: Allocator,
    bundles: []const ErrorBundle,
    build_root: []const u8,
    fallback_path: []const u8,
    read_ctx: *anyopaque,
    read: ReadFn,
) Allocator.Error!BuildResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();

    var lists: std.StringArrayHashMapUnmanaged(std.ArrayList(Item)) = .empty;
    // 去重：多个 compile step 可能报告同一文件的同一错误
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (bundles) |eb| {
        if (eb.errorMessageCount() == 0) continue;
        for (eb.getMessages()) |mi| {
            const msg = eb.getErrorMessage(mi);
            const message = eb.nullTerminatedString(msg.msg);
            var path: []const u8 = fallback_path;
            var start: u32 = 0;
            var end: u32 = 0;
            if (msg.src_loc != .none) {
                const loc = eb.getSourceLocation(msg.src_loc);
                path = try absolute(a, build_root, eb.nullTerminatedString(loc.src_path));
                start = loc.span_start;
                end = loc.span_end;
            }
            const key = try std.fmt.allocPrint(a, "{s}\x00{d}\x00{d}\x00{s}", .{ path, start, end, message });
            if ((try seen.getOrPut(a, key)).found_existing) continue;

            const notes = try a.alloc(Note, msg.notes_len);
            for (notes, eb.getNotes(mi)) |*note, ni| {
                const n = eb.getErrorMessage(ni);
                note.* = .{ .path = path, .start = start, .end = start, .message = try a.dupe(u8, eb.nullTerminatedString(n.msg)) };
                if (n.src_loc != .none) {
                    const nl = eb.getSourceLocation(n.src_loc);
                    note.path = try absolute(a, build_root, eb.nullTerminatedString(nl.src_path));
                    note.start = nl.span_start;
                    note.end = nl.span_end;
                }
            }
            const gop = try lists.getOrPut(a, path);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, .{ .start = start, .end = end, .message = try a.dupe(u8, message), .is_astgen = false, .notes = notes });
        }
    }

    var files: std.StringArrayHashMapUnmanaged(FileResult) = .empty;
    for (lists.keys(), lists.values()) |path, *items| {
        const text = if (read(read_ctx, a, path)) |t| t else "";
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
    return .{ .arena = arena_state.state, .files = files };
}

fn absolute(a: Allocator, base: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolveAlloc(a, &.{path});
    return std.fs.path.resolveAlloc(a, &.{ base, path });
}

// ── 合并（§11.5） ────────────────────────────────────────────────────

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

pub const OtherFile = struct { uri: []const u8, text: []const u8 };

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
        const edit = diffRegion(c.base_text, in.text);
        for (c.items) |item| {
            if (item.is_astgen) continue;
            const span = remap(edit, item.start, item.end) orelse continue;
            try out.append(arena, try compilerDiagnostic(arena, in, item, span[0], span[1]));
        }
    }
    return out.items;
}

/// 新旧文本的差异区间：旧文本 [start, old_end) 被替换为新文本 [start, new_end)
const Edit = struct { start: u32, old_end: u32, new_end: u32 };

fn diffRegion(old: []const u8, new: []const u8) Edit {
    const prefix = std.mem.indexOfDiff(u8, old, new) orelse @min(old.len, new.len);
    var suffix: usize = 0;
    const max = @min(old.len, new.len) - prefix;
    while (suffix < max and old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;
    return .{ .start = @intCast(prefix), .old_end = @intCast(old.len - suffix), .new_end = @intCast(new.len - suffix) };
}

/// 区间完全在修改区域之前不变，完全在之后按长度差平移，与修改区域相交返回 null
fn remap(e: Edit, start: u32, end: u32) ?[2]u32 {
    if (end <= e.start) return .{ start, end };
    if (start >= e.old_end) {
        const delta = @as(i64, e.new_end) - @as(i64, e.old_end);
        return .{ @intCast(@as(i64, start) + delta), @intCast(@as(i64, end) + delta) };
    }
    return null;
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
        try related.append(arena, .{
            .location = .{ .uri = other.uri, .range = lines.range(n.start, n.end, in.encoding) },
            .message = try arena.dupe(u8, n.message),
        });
    }
    return .{
        .range = in.lines.range(start, end, in.encoding),
        .severity = .Error,
        .source = "zig",
        .message = .{ .string = try arena.dupe(u8, item.message) },
        .relatedInformation = if (related.items.len == 0) null else related.items,
    };
}

test {
    _ = @import("compiler_test.zig");
}
