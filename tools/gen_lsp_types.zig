//! Generates `src/lsp/types.zig` from the official LSP metaModel.json.
//!
//! Usage: gen_lsp_types <metaModel.json> <output path>

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Gen = struct {
    arena: Allocator,
    w: *Writer,
    structures: std.StringArrayHashMapUnmanaged(json.Value) = .empty,
    enumerations: std.StringArrayHashMapUnmanaged(json.Value) = .empty,
    aliases: std.StringArrayHashMapUnmanaged(json.Value) = .empty,
    /// String enums that allow custom values; fields of these types use `[]const u8` directly
    open_string_enums: std.StringHashMapUnmanaged(void) = .empty,
    /// Reachability cache on the by-value containment graph, key = "from\x00to"
    reach_cache: std.StringHashMapUnmanaged(bool) = .empty,

    /// LSP aliases that map directly to std.json
    const special_aliases = std.StaticStringMap([]const u8).initComptime(.{
        .{ "LSPAny", "std.json.Value" },
        .{ "LSPObject", "std.json.ArrayHashMap(std.json.Value)" },
        .{ "LSPArray", "[]const std.json.Value" },
    });

    // ── metaModel access: panic with context on unexpected formats, to debug metaModel upgrades ──

    fn invalid(v: json.Value, comptime fmt: []const u8, args: anytype) noreturn {
        var buf: [512]u8 = undefined;
        var w: Writer = .fixed(&buf);
        json.Stringify.value(v, .{}, &w) catch {};
        const shown = w.buffered();
        std.debug.panic("unexpected metaModel format: " ++ fmt ++ "\nnode: {s}{s}", args ++ .{ shown, if (shown.len == buf.len) "…" else "" });
    }

    fn obj(v: json.Value) json.ObjectMap {
        if (v != .object) invalid(v, "expected object", .{});
        return v.object;
    }

    /// Optional field
    fn opt(v: json.Value, key: []const u8) ?json.Value {
        return obj(v).get(key);
    }

    /// Required field
    fn field(v: json.Value, key: []const u8) json.Value {
        return opt(v, key) orelse invalid(v, "missing field \"{s}\"", .{key});
    }

    /// Optional string field; panics if it is present but not a string
    fn str(v: json.Value, key: []const u8) ?[]const u8 {
        const f = opt(v, key) orelse return null;
        if (f != .string) invalid(v, "field \"{s}\" should be a string", .{key});
        return f.string;
    }

    /// Required string field
    fn req(v: json.Value, key: []const u8) []const u8 {
        return str(v, key) orelse invalid(v, "missing string field \"{s}\"", .{key});
    }

    fn int(v: json.Value, key: []const u8) i64 {
        const f = field(v, key);
        if (f != .integer) invalid(v, "field \"{s}\" should be an integer", .{key});
        return f.integer;
    }

    fn arr(v: json.Value, key: []const u8) []const json.Value {
        const f = opt(v, key) orelse return &.{};
        if (f != .array) invalid(v, "field \"{s}\" should be an array", .{key});
        return f.array.items;
    }

    fn flag(v: json.Value, key: []const u8) bool {
        const f = opt(v, key) orelse return false;
        return f == .bool and f.bool;
    }

    // ── Doc comments ───────────────────────────────────────────────────

    fn doc(g: *Gen, v: json.Value) !void {
        if (str(v, "documentation")) |text| {
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |line| {
                try g.w.print("/// {s}\n", .{std.mem.trimEnd(u8, line, " \r")});
            }
        }
        if (str(v, "deprecated")) |text| {
            const documented = if (str(v, "documentation")) |d| std.mem.indexOf(u8, d, "@deprecated") != null else false;
            if (!documented) try g.w.print("/// @deprecated {s}\n", .{text});
        }
    }

    // ── Recursion detection: by-value containment cycles need pointers ───

    fn byValueRefs(g: *Gen, t: json.Value, out: *std.ArrayList([]const u8)) !void {
        const kind = req(t, "kind");
        if (std.mem.eql(u8, kind, "reference")) {
            try out.append(g.arena, req(t, "name"));
        } else if (std.mem.eql(u8, kind, "or") or std.mem.eql(u8, kind, "and") or std.mem.eql(u8, kind, "tuple")) {
            for (arr(t, "items")) |item| try g.byValueRefs(item, out);
        } else if (std.mem.eql(u8, kind, "literal")) {
            for (arr(field(t, "value"), "properties")) |p| try g.byValueRefs(field(p, "type"), out);
        }
        // array / map are indirect references and form no by-value cycle
    }

    fn edges(g: *Gen, name: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (g.structures.get(name)) |s| {
            const props = try g.flattenProperties(s);
            for (props) |p| try g.byValueRefs(field(p, "type"), &out);
        } else if (g.aliases.get(name)) |a| {
            if (special_aliases.get(name) == null) try g.byValueRefs(field(a, "type"), &out);
        }
        return out.items;
    }

    fn reaches(g: *Gen, from: []const u8, to: []const u8) !bool {
        const key = try g.arena.print("{s}\x00{s}", .{ from, to });
        if (g.reach_cache.get(key)) |r| return r;
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(g.arena, from);
        const result = while (stack.pop()) |cur| {
            if (std.mem.eql(u8, cur, to)) break true;
            if ((try visited.getOrPut(g.arena, cur)).found_existing) continue;
            try stack.appendSlice(g.arena, try g.edges(cur));
        } else false;
        try g.reach_cache.put(g.arena, key, result);
        return result;
    }

    // ── Structure property flattening (extends + mixins) ─────────────────

    fn flattenProperties(g: *Gen, s: json.Value) ![]const json.Value {
        var out: std.ArrayList(json.Value) = .empty;
        for ([_][]const u8{ "extends", "mixins" }) |key| {
            for (arr(s, key)) |base| {
                const base_name = req(base, "name");
                const base_struct = g.structures.get(base_name) orelse invalid(s, "references unknown structure {s}", .{base_name});
                try out.appendSlice(g.arena, try g.flattenProperties(base_struct));
            }
        }
        for (arr(s, "properties")) |p| {
            const name = req(p, "name");
            // A derived structure overrides properties with the same name
            for (out.items, 0..) |existing, i| {
                if (std.mem.eql(u8, req(existing, "name"), name)) {
                    _ = out.orderedRemove(i);
                    break;
                }
            }
            try out.append(g.arena, p);
        }
        return out.items;
    }

    // ── Type expressions ───────────────────────────────────────────────

    const Ctx = struct {
        /// Named type being generated (structure or alias), to decide whether a pointer is needed
        owner: []const u8,
        /// Whether the current position is a by-value position (not inside an array/map)
        by_value: bool = true,
    };

    fn isNullable(t: json.Value) bool {
        const kind = req(t, "kind");
        if (std.mem.eql(u8, kind, "base")) return std.mem.eql(u8, req(t, "name"), "null");
        if (std.mem.eql(u8, kind, "or")) {
            for (arr(t, "items")) |item| if (isNullable(item)) return true;
        }
        return false;
    }

    fn baseType(name: []const u8) []const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "string", "[]const u8" },
            .{ "URI", "[]const u8" },
            .{ "DocumentUri", "[]const u8" },
            .{ "RegExp", "[]const u8" },
            .{ "integer", "i32" },
            .{ "uinteger", "u32" },
            .{ "decimal", "f64" },
            .{ "boolean", "bool" },
            .{ "null", "?void" },
        });
        return map.get(name) orelse std.debug.panic("unknown base type: {s}", .{name});
    }

    /// Emits a type expression. A nullable `or` is emitted as `?T`.
    fn emitType(g: *Gen, t: json.Value, ctx: Ctx) anyerror!void {
        const kind = req(t, "kind");
        const w = g.w;
        if (std.mem.eql(u8, kind, "base")) {
            try w.writeAll(baseType(req(t, "name")));
        } else if (std.mem.eql(u8, kind, "reference")) {
            const name = req(t, "name");
            if (g.open_string_enums.contains(name)) {
                try w.writeAll("[]const u8");
            } else if (ctx.by_value and (std.mem.eql(u8, name, ctx.owner) or try g.reaches(name, ctx.owner))) {
                try w.print("*const {f}", .{std.zig.fmtId(name)});
            } else {
                try w.print("{f}", .{std.zig.fmtId(name)});
            }
        } else if (std.mem.eql(u8, kind, "array")) {
            try w.writeAll("[]const ");
            var inner = ctx;
            inner.by_value = false;
            try g.emitType(field(t, "element"), inner);
        } else if (std.mem.eql(u8, kind, "map")) {
            try w.writeAll("std.json.ArrayHashMap(");
            var inner = ctx;
            inner.by_value = false;
            try g.emitType(field(t, "value"), inner);
            try w.writeAll(")");
        } else if (std.mem.eql(u8, kind, "tuple")) {
            try w.writeAll("struct { ");
            for (arr(t, "items")) |item| {
                try g.emitType(item, ctx);
                try w.writeAll(", ");
            }
            try w.writeAll("}");
        } else if (std.mem.eql(u8, kind, "stringLiteral")) {
            try w.print("json_ext.StringLiteral(\"{f}\")", .{std.zig.fmtString(req(t, "value"))});
        } else if (std.mem.eql(u8, kind, "literal")) {
            try w.writeAll("struct {\n");
            for (arr(field(t, "value"), "properties")) |p| try g.emitProperty(p, ctx);
            try w.writeAll("}");
        } else if (std.mem.eql(u8, kind, "or")) {
            try g.emitOr(t, ctx);
        } else {
            std.debug.panic("unsupported type kind: {s}", .{kind});
        }
    }

    fn collectOrItems(g: *Gen, t: json.Value, out: *std.ArrayList(json.Value)) !void {
        for (arr(t, "items")) |item| {
            const kind = req(item, "kind");
            if (std.mem.eql(u8, kind, "or")) {
                try g.collectOrItems(item, out);
            } else if (!(std.mem.eql(u8, kind, "base") and std.mem.eql(u8, req(item, "name"), "null"))) {
                try out.append(g.arena, item);
            }
        }
    }

    fn emitOr(g: *Gen, t: json.Value, ctx: Ctx) !void {
        var items: std.ArrayList(json.Value) = .empty;
        try g.collectOrItems(t, &items);
        if (isNullable(t)) try g.w.writeAll("?");
        if (items.items.len == 1) return g.emitType(items.items[0], ctx);

        try g.w.writeAll("union(enum) {\n");
        var used: std.StringHashMapUnmanaged(void) = .empty;
        for (items.items) |item| {
            var name = try g.variantName(item);
            var n: usize = 2;
            while ((try used.getOrPut(g.arena, name)).found_existing) : (n += 1) {
                name = try g.arena.print("{s}_{d}", .{ try g.variantName(item), n });
            }
            try g.w.print("{f}: ", .{std.zig.fmtId(name)});
            try g.emitType(item, ctx);
            try g.w.writeAll(",\n");
        }
        try g.w.writeAll(
            \\pub const jsonParse = json_ext.Union(@This()).jsonParse;
            \\pub const jsonParseFromValue = json_ext.Union(@This()).jsonParseFromValue;
            \\pub const jsonStringify = json_ext.Union(@This()).jsonStringify;
            \\}
        );
    }

    fn variantName(g: *Gen, t: json.Value) ![]const u8 {
        const kind = req(t, "kind");
        if (std.mem.eql(u8, kind, "reference") or std.mem.eql(u8, kind, "base")) return req(t, "name");
        if (std.mem.eql(u8, kind, "array")) return g.arena.print("array_of_{s}", .{try g.variantName(field(t, "element"))});
        if (std.mem.eql(u8, kind, "stringLiteral")) return req(t, "value");
        return kind;
    }

    fn emitProperty(g: *Gen, p: json.Value, ctx: Ctx) !void {
        try g.doc(p);
        const t = field(p, "type");
        const optional = flag(p, "optional");
        try g.w.print("{f}: ", .{std.zig.fmtId(req(p, "name"))});
        if (optional and !isNullable(t)) try g.w.writeAll("?");
        try g.emitType(t, ctx);
        if (optional or isNullable(t)) {
            try g.w.writeAll(" = null");
        } else if (std.mem.eql(u8, req(t, "kind"), "stringLiteral")) {
            try g.w.writeAll(" = .{}");
        }
        try g.w.writeAll(",\n");
    }

    // ── Top-level declarations ─────────────────────────────────────────

    fn emitStructure(g: *Gen, name: []const u8, s: json.Value) !void {
        try g.doc(s);
        try g.w.print("pub const {f} = struct {{\n", .{std.zig.fmtId(name)});
        for (try g.flattenProperties(s)) |p| try g.emitProperty(p, .{ .owner = name });
        try g.w.writeAll("};\n\n");
    }

    fn emitEnumeration(g: *Gen, name: []const u8, e: json.Value) !void {
        try g.doc(e);
        const base = req(field(e, "type"), "name");
        const values = arr(e, "values");
        if (std.mem.eql(u8, base, "string")) {
            if (flag(e, "supportsCustomValues")) {
                // Open enum: the field type is []const u8; only constants are provided here
                try g.w.print("pub const {f} = struct {{\n", .{std.zig.fmtId(name)});
                for (values) |v| {
                    try g.doc(v);
                    try g.w.print("pub const {f}: []const u8 = \"{f}\";\n", .{ std.zig.fmtId(req(v, "name")), std.zig.fmtString(req(v, "value")) });
                }
            } else {
                // Closed string enum: the tag names are the JSON values, so std.json can parse
                // and serialize it directly
                try g.w.print("pub const {f} = enum {{\n", .{std.zig.fmtId(name)});
                for (values) |v| {
                    try g.doc(v);
                    try g.w.print("{f},\n", .{std.zig.fmtId(req(v, "value"))});
                }
            }
        } else {
            const tag = if (std.mem.eql(u8, base, "uinteger")) "u32" else "i32";
            try g.w.print("pub const {f} = enum({s}) {{\n", .{ std.zig.fmtId(name), tag });
            for (values) |v| {
                try g.doc(v);
                try g.w.print("{f} = {d},\n", .{ std.zig.fmtId(req(v, "name")), int(v, "value") });
            }
            try g.w.writeAll("_,\n\npub const jsonStringify = json_ext.IntEnum(@This()).jsonStringify;\n");
        }
        try g.w.writeAll("};\n\n");
    }

    fn emitAlias(g: *Gen, name: []const u8, a: json.Value) !void {
        try g.doc(a);
        try g.w.print("pub const {f} = ", .{std.zig.fmtId(name)});
        if (special_aliases.get(name)) |target| {
            try g.w.writeAll(target);
        } else {
            try g.emitType(field(a, "type"), .{ .owner = name });
        }
        try g.w.writeAll(";\n\n");
    }

    fn emitMessages(g: *Gen, items: []const json.Value, is_request: bool) !void {
        try g.w.print("pub const {s} = [_]{s}{{\n", .{
            if (is_request) "requests" else "notifications",
            if (is_request) "RequestInfo" else "NotificationInfo",
        });
        for (items) |m| {
            const method = req(m, "method");
            try g.w.print(".{{ .method = \"{f}\", .direction = .{s}, .Params = ", .{ std.zig.fmtString(method), req(m, "messageDirection") });
            if (opt(m, "params")) |params| {
                try g.emitType(params, .{ .owner = "", .by_value = false });
            } else {
                try g.w.writeAll("void");
            }
            if (is_request) {
                try g.w.writeAll(", .Result = ");
                try g.emitType(field(m, "result"), .{ .owner = "", .by_value = false });
            }
            try g.w.writeAll(" },\n");
        }
        try g.w.writeAll("};\n\n");
    }

    fn run(g: *Gen, model: json.Value) !void {
        for (arr(model, "structures")) |s| try g.structures.put(g.arena, req(s, "name"), s);
        for (arr(model, "enumerations")) |e| {
            try g.enumerations.put(g.arena, req(e, "name"), e);
            if (std.mem.eql(u8, req(field(e, "type"), "name"), "string") and flag(e, "supportsCustomValues")) {
                try g.open_string_enums.put(g.arena, req(e, "name"), {});
            }
        }
        for (arr(model, "typeAliases")) |a| try g.aliases.put(g.arena, req(a, "name"), a);

        const version = req(field(model, "metaData"), "version");
        try g.w.print(
            \\//! 由 tools/gen_lsp_types.zig 从 metaModel.json（LSP {s}）生成，请勿手改。
            \\
            \\const std = @import("std");
            \\const json_ext = @import("json_ext.zig");
            \\
            \\pub const version = "{s}";
            \\
            \\pub const MessageDirection = enum {{ clientToServer, serverToClient, both }};
            \\
            \\pub const RequestInfo = struct {{
            \\    method: []const u8,
            \\    direction: MessageDirection,
            \\    Params: type,
            \\    Result: type,
            \\}};
            \\
            \\pub const NotificationInfo = struct {{
            \\    method: []const u8,
            \\    direction: MessageDirection,
            \\    Params: type,
            \\}};
            \\
            \\pub fn ParamsType(comptime method: []const u8) type {{
            \\    @setEvalBranchQuota(10_000);
            \\    for (requests) |r| if (std.mem.eql(u8, r.method, method)) return r.Params;
            \\    for (notifications) |n| if (std.mem.eql(u8, n.method, method)) return n.Params;
            \\    @compileError("unknown LSP method: " ++ method);
            \\}}
            \\
            \\pub fn ResultType(comptime method: []const u8) type {{
            \\    @setEvalBranchQuota(10_000);
            \\    for (requests) |r| if (std.mem.eql(u8, r.method, method)) return r.Result;
            \\    @compileError("unknown LSP request: " ++ method);
            \\}}
            \\
            \\pub fn isRequest(comptime method: []const u8) bool {{
            \\    @setEvalBranchQuota(10_000);
            \\    for (requests) |r| if (std.mem.eql(u8, r.method, method)) return true;
            \\    return false;
            \\}}
            \\
            \\
        , .{ version, version });

        try g.emitMessages(arr(model, "requests"), true);
        try g.emitMessages(arr(model, "notifications"), false);
        for (g.structures.keys(), g.structures.values()) |name, s| try g.emitStructure(name, s);
        for (g.enumerations.keys(), g.enumerations.values()) |name, e| try g.emitEnumeration(name, e);
        for (g.aliases.keys(), g.aliases.values()) |name, a| try g.emitAlias(name, a);
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: {s} <metaModel.json> <output path>\n", .{args[0]});
        std.process.exit(1);
    }

    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(io, args[1], arena, .limited(16 * 1024 * 1024));
    const model = try json.parseFromSliceLeaky(json.Value, arena, input, .{});

    var out: Writer.Allocating = .init(arena);
    var gen: Gen = .{ .arena = arena, .w = &out.writer };
    try gen.run(model);

    // Format the output with std.zig; on failure, print the errors to help debug the generator
    const source = try out.toOwnedSliceSentinel(0);
    var tree = try std.zig.Ast.parse(arena, source, .{});
    if (tree.errors.len != 0) {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        for (tree.errors) |err| {
            const loc = tree.tokenLocation(0, err.token);
            try stderr.interface.print("{s}:{d}:{d}: ", .{ args[2], loc.line + 1, loc.column + 1 });
            try tree.renderError(err, &stderr.interface);
            try stderr.interface.writeAll("\n");
        }
        try cwd.writeFile(io, .{ .sub_path = args[2], .data = source });
        std.process.exit(1);
    }
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = try tree.renderAlloc(arena) });
}
