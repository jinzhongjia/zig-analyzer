//! Generates builtin function metadata from a pinned version of the official Zig language
//! reference; does not access the network.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const official = @import("zig_source.zig");
const pinned_version = official.pinned_version;
const Metadata = official.Metadata;
const checkHash = official.checkHash;
const validateMetadata = official.validateMetadata;
const documented_count = 124;
const compiler_only = [_][]const u8{ "@Frame", "@frame", "@disableInstrumentation", "@disableIntrinsics" };

fn invalid(comptime fmt: []const u8, args: anytype) error{InvalidOfficialSource} {
    // Tests construct invalid input on purpose; printing to stderr would put a misleading
    // `failed command` in the build output
    if (!@import("builtin").is_test) std.debug.print("builtin metadata: " ++ fmt ++ "\n", args);
    return error.InvalidOfficialSource;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn sectionUrl(a: Allocator, base: []const u8, title: []const u8) ![]const u8 {
    // Same anchor rules as the official docgen: drop punctuation and replace spaces with hyphens.
    var anchor: Writer.Allocating = .init(a);
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-')
            try anchor.writer.writeByte(c)
        else if (c == ' ')
            try anchor.writer.writeByte('-');
    }
    return std.fmt.allocPrint(a, "{s}#{s}", .{ base, anchor.writer.buffered() });
}

fn decodeEntities(a: Allocator, input: []const u8) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.writer.writeByte(input[i]);
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, input, i, ';') orelse return invalid("unterminated HTML entity", .{});
        const entity = input[i + 1 .. end];
        const named = std.StaticStringMap([]const u8).initComptime(.{
            .{ "amp", "&" },  .{ "lt", "<" }, .{ "gt", ">" }, .{ "quot", "\"" }, .{ "apos", "'" },
            .{ "nbsp", " " },
            .{ "ndash", "–" },
            .{ "mdash", "—" },
            .{ "hellip", "…" },
            .{ "lsquo", "‘" },
            .{ "rsquo", "’" },
            .{ "ldquo", "“" },
            .{ "rdquo", "”" },
        });
        if (named.get(entity)) |value| {
            try out.writer.writeAll(value);
        } else if (std.mem.startsWith(u8, entity, "#")) {
            const hex = entity.len > 1 and (entity[1] == 'x' or entity[1] == 'X');
            const value = std.fmt.parseInt(u21, entity[if (hex) 2 else 1..], if (hex) 16 else 10) catch
                return invalid("invalid numeric HTML entity: &{s};", .{entity});
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(value, &buf) catch return invalid("invalid Unicode HTML entity: &{s};", .{entity});
            try out.writer.writeAll(buf[0..len]);
        } else return invalid("unsupported HTML entity: &{s};", .{entity});
        i = end + 1;
    }
    return out.toOwnedSlice();
}

const Signature = struct {
    label: []const u8,
    parameters: []const []const u8,
    variadic: bool,
};

fn parseSignature(a: Allocator, name: []const u8, raw: []const u8) !Signature {
    // Parameter comments in multiline upstream signatures are for display only and are not part
    // of the parameter labels.
    var normalized: Writer.Allocating = .init(a);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const comment = std.mem.indexOf(u8, line, "//") orelse line.len;
        for (line[0..comment]) |c| {
            if (std.ascii.isWhitespace(c)) {
                if (normalized.writer.buffered().len != 0 and normalized.writer.buffered()[normalized.writer.buffered().len - 1] != ' ')
                    try normalized.writer.writeByte(' ');
            } else try normalized.writer.writeByte(c);
        }
        if (normalized.writer.buffered().len != 0 and normalized.writer.buffered()[normalized.writer.buffered().len - 1] != ' ')
            try normalized.writer.writeByte(' ');
    }
    const label = trim(try normalized.toOwnedSlice());
    if (!std.mem.startsWith(u8, label, name) or label.len <= name.len or label[name.len] != '(')
        return invalid("signature does not start with {s}(: {s}", .{ name, label });
    var params: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList(u8) = .empty;
    var start = name.len + 1;
    var i = start;
    var quote: ?u8 = null;
    var escaped = false;
    while (i < label.len) : (i += 1) {
        const c = label[i];
        if (quote) |q| {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        switch (c) {
            '(', '[', '{' => try stack.append(a, c),
            ')', ']', '}' => {
                if (c == ')' and stack.items.len == 0) {
                    const param = trim(label[start..i]);
                    if (param.len != 0) try params.append(a, param);
                    if (trim(label[i + 1 ..]).len == 0) return invalid("missing return type in {s}", .{name});
                    var variadic = false;
                    for (params.items, 0..) |p, index| {
                        if (eql(p, "...")) {
                            if (index + 1 != params.items.len) return invalid("variadic parameter is not last in {s}", .{name});
                            variadic = true;
                        }
                    }
                    return .{ .label = label, .parameters = try params.toOwnedSlice(a), .variadic = variadic };
                }
                const open = stack.pop() orelse return invalid("unbalanced signature delimiters in {s}", .{name});
                if ((c == ')' and open != '(') or (c == ']' and open != '[') or (c == '}' and open != '{'))
                    return invalid("mismatched signature delimiters in {s}", .{name});
            },
            ',' => if (stack.items.len == 0) {
                const param = trim(label[start..i]);
                if (param.len == 0) return invalid("empty signature parameter in {s}", .{name});
                try params.append(a, param);
                start = i + 1;
            },
            else => {},
        }
    }
    return invalid("unterminated signature for {s}", .{name});
}

fn validateArity(name: []const u8, sig: Signature, count: ?u8) !void {
    // Display types such as T, DestType, and Log2T are not implicit parameters; count only the
    // actual parameters inside the outermost parentheses.
    if (count) |fixed| {
        if (sig.variadic or sig.parameters.len != fixed)
            return invalid("official signature/compiler arity mismatch for {s}: documented {d}{s}, compiler {d}", .{ name, sig.parameters.len, if (sig.variadic) " (variadic)" else "", fixed });
    } else if (!sig.variadic) return invalid("compiler marks {s} variadic but its official signature does not", .{name});
}

const Markdown = struct {
    a: Allocator,
    base: []const u8,
    version: []const u8,
    example_url: ?[]const u8 = null,
    out: std.ArrayList(u8) = .empty,
    list_depth: usize = 0,

    fn put(m: *Markdown, bytes: []const u8) !void {
        try m.out.appendSlice(m.a, bytes);
    }

    fn breaks(m: *Markdown, count: usize) !void {
        while (m.out.items.len > 0 and m.out.items[m.out.items.len - 1] == ' ') m.out.items.len -= 1;
        if (m.out.items.len == 0) return;
        var n: usize = 0;
        var i = m.out.items.len;
        while (i > 0 and m.out.items[i - 1] == '\n') : (i -= 1) n += 1;
        while (n < count) : (n += 1) try m.put("\n");
    }

    fn text(m: *Markdown, raw: []const u8) !void {
        const decoded = try decodeEntities(m.a, raw);
        for (decoded) |c| {
            if (std.ascii.isWhitespace(c)) {
                if (m.out.items.len > 0 and !std.ascii.isWhitespace(m.out.items[m.out.items.len - 1])) try m.put(" ");
            } else {
                if (std.mem.indexOfScalar(u8, "\\`*_[]", c) != null) try m.put("\\");
                try m.out.append(m.a, c);
            }
        }
    }

    fn code(m: *Markdown, raw: []const u8, block: bool, language: []const u8) !void {
        const value = try decodeEntities(m.a, if (block) std.mem.trim(u8, raw, "\r\n") else raw);
        var longest: usize = 0;
        var run: usize = 0;
        for (value) |c| {
            run = if (c == '`') run + 1 else 0;
            longest = @max(longest, run);
        }
        const fence = try m.a.alloc(u8, @max(if (block) @as(usize, 3) else 1, longest + 1));
        @memset(fence, '`');
        if (block) try m.breaks(2);
        try m.put(fence);
        if (block) {
            try m.put(language);
            try m.put("\n");
        }
        const pad = !block and value.len > 0 and (value[0] == '`' or value[value.len - 1] == '`');
        if (pad) try m.put(" ");
        try m.put(value);
        if (pad) try m.put(" ");
        if (block) try m.put("\n");
        try m.put(fence);
        if (block) try m.breaks(2);
    }

    fn link(m: *Markdown, label: []const u8, url: []const u8) !void {
        try m.put("[");
        try m.text(label);
        try m.put("](");
        try m.put(url);
        try m.put(")");
    }

    fn directive(m: *Markdown, value: []const u8) !void {
        var parts = std.mem.splitScalar(u8, value, '|');
        const kind = parts.next().?;
        if (eql(kind, "link")) {
            const label = parts.next() orelse return invalid("missing link label", .{});
            const target = parts.next() orelse label;
            if (parts.next() != null) return invalid("too many link fields", .{});
            try m.link(label, try sectionUrl(m.a, m.base, target));
        } else if (eql(kind, "see_also")) {
            try m.breaks(2);
            try m.put("See also: ");
            var first = true;
            while (parts.next()) |target| {
                // The official see_also of @atomicLoad has an empty field;
                // no empty link is generated.
                if (target.len == 0) continue;
                if (!first) try m.put(", ");
                first = false;
                try m.link(target, try sectionUrl(m.a, m.base, target));
            }
            try m.breaks(2);
        } else if (eql(kind, "code")) {
            const filename = parts.next() orelse return invalid("missing example filename", .{});
            if (parts.next() != null) return invalid("too many example fields", .{});
            try m.breaks(2);
            try m.put("Official example: ");
            try m.link(filename, m.example_url orelse m.base);
            try m.breaks(2);
        } else if (eql(kind, "header_open")) {
            try m.breaks(2);
            try m.put("### ");
            try m.text(parts.next() orelse return invalid("missing subsection title", .{}));
            try m.breaks(2);
        } else if (eql(kind, "header_close")) {
            try m.breaks(2);
        } else return invalid("unsupported documentation directive: {s}", .{kind});
    }

    fn table(m: *Markdown, raw: []const u8) !void {
        try m.breaks(2);
        var pos: usize = 0;
        var row: usize = 0;
        var width: usize = 0;
        while (std.mem.indexOfPos(u8, raw, pos, "<tr")) |start| {
            const open = std.mem.indexOfScalarPos(u8, raw, start, '>') orelse return invalid("unterminated table row", .{});
            const end = std.mem.indexOfPos(u8, raw, open, "</tr>") orelse return invalid("missing table row close", .{});
            var cell_pos = open + 1;
            var cells: usize = 0;
            try m.put("| ");
            while (std.mem.indexOfPos(u8, raw, cell_pos, "<t")) |cell_start| {
                if (cell_start >= end) break;
                if (cell_start + 3 >= raw.len or (raw[cell_start + 2] != 'h' and raw[cell_start + 2] != 'd'))
                    return invalid("unexpected tag inside table row", .{});
                const cell_open = std.mem.indexOfScalarPos(u8, raw, cell_start, '>') orelse return invalid("unterminated table cell", .{});
                const close = if (raw[cell_start + 2] == 'h') "</th>" else "</td>";
                const cell_end = std.mem.indexOfPos(u8, raw, cell_open, close) orelse return invalid("missing table cell close", .{});
                if (cell_end > end) return invalid("table cell crosses row boundary", .{});
                var child: Markdown = .{ .a = m.a, .base = m.base, .version = m.version };
                const rendered = try child.render(raw[cell_open + 1 .. cell_end]);
                for (rendered) |c| {
                    if (c == '|') try m.put("\\");
                    try m.out.append(m.a, if (c == '\n') ' ' else c);
                }
                try m.put(" | ");
                cells += 1;
                cell_pos = cell_end + close.len;
            }
            if (cells == 0 or (row != 0 and width != cells)) return invalid("inconsistent Markdown table width", .{});
            try m.breaks(1);
            if (row == 0) {
                width = cells;
                try m.put("|");
                for (0..width) |_| try m.put(" --- |");
                try m.breaks(1);
            }
            row += 1;
            pos = end + "</tr>".len;
        }
        if (row == 0) return invalid("empty documentation table", .{});
        try m.breaks(2);
    }

    fn render(m: *Markdown, input: []const u8) anyerror![]const u8 {
        var i: usize = 0;
        while (i < input.len) {
            if (std.mem.startsWith(u8, input[i..], "{#syntax#}")) {
                const start = i + "{#syntax#}".len;
                const end = std.mem.indexOfPos(u8, input, start, "{#endsyntax#}") orelse return invalid("missing endsyntax", .{});
                try m.code(input[start..end], false, "");
                i = end + "{#endsyntax#}".len;
            } else if (std.mem.startsWith(u8, input[i..], "{#syntax_block|")) {
                const open = std.mem.indexOfPos(u8, input, i, "#}") orelse return invalid("unterminated syntax_block", .{});
                var parts = std.mem.splitScalar(u8, input[i + "{#syntax_block|".len .. open], '|');
                const language = parts.next().?;
                if (language.len == 0) return invalid("missing syntax block language", .{});
                const end = std.mem.indexOfPos(u8, input, open, "{#end_syntax_block#}") orelse return invalid("missing end_syntax_block", .{});
                try m.code(input[open + 2 .. end], true, language);
                i = end + "{#end_syntax_block#}".len;
            } else if (std.mem.startsWith(u8, input[i..], "{#")) {
                const end = std.mem.indexOfPos(u8, input, i, "#}") orelse return invalid("unterminated template directive", .{});
                try m.directive(input[i + 2 .. end]);
                i = end + 2;
            } else if (input[i] == '<') {
                const end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse return invalid("unterminated HTML tag", .{});
                const tag = input[i + 1 .. end];
                const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n") orelse tag.len;
                const name = tag[0..name_end];
                if (eql(name, "pre") or eql(name, "code")) {
                    const block = eql(name, "pre");
                    const closing = if (block) "</pre>" else "</code>";
                    const close = std.mem.indexOfPos(u8, input, end, closing) orelse return invalid("missing {s}", .{closing});
                    var content = trim(input[end + 1 .. close]);
                    var language: []const u8 = "";
                    if (std.mem.startsWith(u8, content, "{#syntax#}")) {
                        if (!std.mem.endsWith(u8, content, "{#endsyntax#}")) return invalid("malformed syntax inside pre", .{});
                        content = content["{#syntax#}".len .. content.len - "{#endsyntax#}".len];
                        language = "zig";
                    } else if (std.mem.startsWith(u8, content, "<code>")) {
                        if (!std.mem.endsWith(u8, content, "</code>")) return invalid("malformed code inside pre", .{});
                        content = content["<code>".len .. content.len - "</code>".len];
                    }
                    try m.code(content, block, language);
                    i = close + closing.len;
                    continue;
                } else if (eql(name, "table")) {
                    const close = std.mem.indexOfPos(u8, input, end, "</table>") orelse return invalid("missing table close", .{});
                    try m.table(input[end + 1 .. close]);
                    i = close + "</table>".len;
                    continue;
                } else if (eql(name, "a")) {
                    const attr = std.mem.indexOf(u8, tag, "href=\"") orelse return invalid("anchor missing href", .{});
                    const url_start = attr + "href=\"".len;
                    const url_end = std.mem.indexOfScalarPos(u8, tag, url_start, '"') orelse return invalid("unterminated href", .{});
                    const close = std.mem.indexOfPos(u8, input, end, "</a>") orelse return invalid("missing anchor close", .{});
                    const href = try decodeEntities(m.a, tag[url_start..url_end]);
                    const url = if (std.mem.startsWith(u8, href, "https://") or std.mem.startsWith(u8, href, "http://")) href else try std.fmt.allocPrint(m.a, "{s}{s}", .{ m.base, href });
                    try m.put("[");
                    var child: Markdown = .{ .a = m.a, .base = m.base, .version = m.version };
                    try m.put(try child.render(input[end + 1 .. close]));
                    try m.put("](");
                    try m.put(url);
                    try m.put(")");
                    i = close + "</a>".len;
                    continue;
                } else if (eql(name, "p") or eql(name, "/p")) {
                    try m.breaks(2);
                } else if (eql(name, "ul") or eql(name, "ol")) {
                    try m.breaks(if (m.list_depth == 0) 2 else 1);
                    m.list_depth += 1;
                } else if (eql(name, "/ul") or eql(name, "/ol")) {
                    if (m.list_depth == 0) return invalid("unmatched list close", .{});
                    m.list_depth -= 1;
                    try m.breaks(if (m.list_depth == 0) 2 else 1);
                } else if (eql(name, "li")) {
                    if (m.list_depth == 0) return invalid("list item outside list", .{});
                    try m.breaks(1);
                    for (1..m.list_depth) |_| try m.put("  ");
                    try m.put("- ");
                } else if (eql(name, "/li")) {
                    try m.breaks(1);
                } else if (eql(name, "em") or eql(name, "/em")) {
                    try m.put("*");
                } else if (eql(name, "strong") or eql(name, "/strong")) {
                    try m.put("**");
                } else if (eql(name, "br") or eql(name, "br/")) {
                    try m.breaks(1);
                } else if (!eql(name, "div") and !eql(name, "/div")) return invalid("unsupported HTML tag: {s}", .{name});
                i = end + 1;
            } else {
                var end = i + 1;
                while (end < input.len and input[end] != '<' and !std.mem.startsWith(u8, input[end..], "{#")) : (end += 1) {}
                try m.text(input[i..end]);
                i = end;
            }
        }
        if (m.list_depth != 0) return invalid("unclosed documentation list", .{});
        return trim(m.out.items);
    }
};

const Document = struct { signature: Signature, documentation: []const u8 };

fn parseDocuments(a: Allocator, input: []const u8, metadata: Metadata) !std.StringHashMapUnmanaged(Document) {
    var result: std.StringHashMapUnmanaged(Document) = .empty;
    const marker = "{#header_open|@";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, input, pos, marker)) |start| {
        const title_end = std.mem.indexOfPos(u8, input, start, "#}") orelse return invalid("unterminated builtin heading", .{});
        const name = input[start + "{#header_open|".len .. title_end];
        if (std.zig.BuiltinFn.list.get(name) == null) return invalid("official documented builtin absent from compiler: {s}", .{name});
        var depth: usize = 1;
        var scan = title_end + 2;
        var body_end: usize = undefined;
        while (true) {
            const directive = std.mem.indexOfPos(u8, input, scan, "{#") orelse return invalid("unclosed builtin section: {s}", .{name});
            const end = std.mem.indexOfPos(u8, input, directive, "#}") orelse return invalid("unterminated directive in {s}", .{name});
            const value = input[directive + 2 .. end];
            if (std.mem.startsWith(u8, value, "header_open|")) depth += 1 else if (eql(value, "header_close")) {
                depth -= 1;
                if (depth == 0) {
                    body_end = directive;
                    pos = end + 2;
                    break;
                }
            }
            scan = end + 2;
        }
        const body = trim(input[title_end + 2 .. body_end]);
        const prefix = "<pre>{#syntax#}";
        const suffix = "{#endsyntax#}</pre>";
        if (!std.mem.startsWith(u8, body, prefix)) return invalid("missing initial official signature for {s}", .{name});
        const sig_end = std.mem.indexOf(u8, body, suffix) orelse return invalid("unclosed official signature for {s}", .{name});
        const signature = try parseSignature(a, name, body[prefix.len..sig_end]);
        try validateArity(name, signature, std.zig.BuiltinFn.list.get(name).?.param_count);
        const source_url = try sectionUrl(a, metadata.documentation_url, name);
        var markdown: Markdown = .{ .a = a, .base = metadata.documentation_url, .version = metadata.version, .example_url = source_url };
        const description = try markdown.render(body[sig_end + suffix.len ..]);
        if (description.len == 0) return invalid("empty official documentation for {s}", .{name});
        const documentation = try std.fmt.allocPrint(a, "{s}\n\n[Zig {s} Language Reference]({s})", .{ description, metadata.version, source_url });
        const entry = try result.getOrPut(a, name);
        if (entry.found_existing) return invalid("duplicate official builtin section: {s}", .{name});
        entry.value_ptr.* = .{ .signature = signature, .documentation = documentation };
    }
    if (result.count() != documented_count) return invalid("official documentation coverage mismatch: expected {d}, got {d}", .{ documented_count, result.count() });
    return result;
}

fn generate(a: Allocator, input: []const u8, metadata: Metadata) ![:0]const u8 {
    const docs = try parseDocuments(a, input, metadata);
    const registry = std.zig.BuiltinFn.list;
    if (registry.keys().len != documented_count + compiler_only.len)
        return invalid("compiler builtin coverage mismatch: expected {d}, got {d}", .{ documented_count + compiler_only.len, registry.keys().len });
    const names = try a.dupe([]const u8, registry.keys());
    std.mem.sort([]const u8, names, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("//! Generated by tools/gen_builtin_data.zig from the official MIT-licensed Zig documentation.\n");
    try w.writeAll("//! Do not edit by hand.\n");
    try w.writeAll("//! Copyright and license: see tools/zig/LICENSE; pinned sources: see tools/zig/metadata.json.\n");
    try w.writeAll("const Entry = @import(\"builtins.zig\").Entry;\n");
    try w.print("pub const version = \"{f}\";\n", .{std.zig.fmtString(metadata.version)});
    try w.print("pub const langref_sha256 = \"{f}\";\n", .{std.zig.fmtString(metadata.langref_sha256)});
    try w.print("pub const builtin_registry_sha256 = \"{f}\";\n", .{std.zig.fmtString(metadata.builtin_registry_sha256)});
    try w.writeAll("pub const entries = [_]Entry{\n");
    for (names) |name| {
        const compiler = registry.get(name).?;
        const doc = docs.get(name);
        const source_url = try sectionUrl(a, metadata.documentation_url, if (doc != null) name else "Builtin Functions");
        try w.print(".{{ .name = \"{f}\", .signature = ", .{std.zig.fmtString(name)});
        if (doc) |d| try w.print("\"{f}\"", .{std.zig.fmtString(d.signature.label)}) else try w.writeAll("null");
        try w.writeAll(", .parameters = &.{");
        if (doc) |d| for (d.signature.parameters) |param| try w.print("\"{f}\",", .{std.zig.fmtString(param)});
        try w.writeAll("}, .documentation = ");
        if (doc) |d| {
            try w.print("\"{f}\"", .{std.zig.fmtString(d.documentation)});
        } else {
            var allowed = false;
            for (compiler_only) |known| {
                if (eql(known, name)) allowed = true;
            }
            if (!allowed) return invalid("compiler builtin lacks official documentation: {s}", .{name});
            const count = if (compiler.param_count) |n| try std.fmt.allocPrint(a, "{d}", .{n}) else "variable";
            const note = try std.fmt.allocPrint(a, "`{s}` is present in the Zig {s} compiler builtin registry (parameter count: {s}), but has no entry in that version's official Language Reference. No official signature or semantic documentation is available in the vendored source.\n\n[Zig {s} Language Reference]({s}) · [Official compiler source archive]({s}) (`lib/std/zig/BuiltinFn.zig`)", .{ name, metadata.version, count, metadata.version, source_url, metadata.source_archive });
            try w.print("\"{f}\"", .{std.zig.fmtString(note)});
        }
        try w.print(", .variadic = {}, .documented = {}, .source_url = \"{f}\", .compiler_param_count = ", .{ compiler.param_count == null, doc != null, std.zig.fmtString(source_url) });
        if (compiler.param_count) |count| try w.print("{d}", .{count}) else try w.writeAll("null");
        try w.writeAll(" },\n");
    }
    try w.writeAll("};\n");
    return out.toOwnedSliceSentinel(0);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) return invalid("usage: {s} <langref.html.in> <metadata.json> <compiler BuiltinFn.zig> <output path>", .{args[0]});
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, args[1], a, .limited(2 * 1024 * 1024));
    const metadata_bytes = try cwd.readFileAlloc(init.io, args[2], a, .limited(16 * 1024));
    const metadata = try std.json.parseFromSliceLeaky(Metadata, a, metadata_bytes, .{});
    try validateMetadata(a, metadata, @import("builtin").zig_version_string);
    try checkHash(input, metadata.langref_sha256, "official language reference");
    const registry = try cwd.readFileAlloc(init.io, args[3], a, .limited(128 * 1024));
    try checkHash(registry, metadata.builtin_registry_sha256, "compiler builtin registry");
    const source = try generate(a, input, metadata);
    var tree = try std.zig.Ast.parse(a, source, .{});
    if (tree.errors.len != 0) {
        var stderr = std.Io.File.stderr().writer(init.io, &.{});
        for (tree.errors) |err| {
            try tree.renderError(err, &stderr.interface);
            try stderr.interface.writeAll("\n");
        }
        return invalid("generated builtin metadata is not valid Zig", .{});
    }
    try cwd.writeFile(init.io, .{ .sub_path = args[4], .data = try tree.renderAlloc(a) });
}

test "signature parser preserves nested types and exact parameter label slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sig = try parseSignature(arena.allocator(), "@example", "@example(comptime F: fn (u8, u16) void, x: @Vector(4, u8), comptime values: [2]u8,) @TypeOf(F, x)");
    try std.testing.expectEqual(@as(usize, 3), sig.parameters.len);
    try std.testing.expectEqualStrings("comptime F: fn (u8, u16) void", sig.parameters[0]);
    try std.testing.expectEqualStrings("x: @Vector(4, u8)", sig.parameters[1]);
    try std.testing.expectEqualStrings("comptime values: [2]u8", sig.parameters[2]);
    try std.testing.expect(std.mem.endsWith(u8, sig.label, "@TypeOf(F, x)"));
}

test "multiline official signatures remove source comments without inventing parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sig = try parseSignature(arena.allocator(), "@Union", "@Union(\n comptime layout: Layout,\n /// Explanation, with comma.\n comptime ArgType: ?type,\n) type");
    try std.testing.expectEqual(@as(usize, 2), sig.parameters.len);
    try std.testing.expectEqualStrings("comptime ArgType: ?type", sig.parameters[1]);
    try std.testing.expect(std.mem.indexOf(u8, sig.label, "Explanation") == null);
    try validateArity("@Union", sig, 2);
    try std.testing.expectError(error.InvalidOfficialSource, validateArity("@Union", sig, 3));
    try std.testing.expectError(error.InvalidOfficialSource, parseSignature(arena.allocator(), "@x", "@x(a: [2)u8) void"));
}

test "variadic signatures and compiler arity must agree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sig = try parseSignature(arena.allocator(), "@TypeOf", "@TypeOf(...) type");
    try std.testing.expect(sig.variadic);
    try std.testing.expectEqualStrings("...", sig.parameters[0]);
    try validateArity("@TypeOf", sig, null);
    try std.testing.expectError(error.InvalidOfficialSource, validateArity("@TypeOf", sig, 1));
}

test "Markdown renders templates examples entities nested lists and tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m: Markdown = .{ .a = arena.allocator(), .base = "https://ziglang.org/documentation/0.17.0/", .version = pinned_version, .example_url = "https://ziglang.org/documentation/0.17.0/#call" };
    const rendered = try m.render("<p>A &amp; B &#x3c; C {#link|integer|Integers#}.</p><ul><li>outer<ul><li><code>x|y</code></li></ul></li></ul>{#code|lang.CallModifier struct.zig#}{#syntax_block|zig|example#}\nconst a = 1;\n{#end_syntax_block#}<table><tr><th>A</th><th>B</th></tr><tr><td><code>x|y</code></td><td>&quot;ok&quot;</td></tr></table>{#see_also|@as||Type Coercion#}");
    try std.testing.expect(std.mem.indexOf(u8, rendered, "A & B < C [integer](https://ziglang.org/documentation/0.17.0/#Integers)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "- outer\n  - `x|y`") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[lang.CallModifier struct.zig](https://ziglang.org/documentation/0.17.0/#call)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "```zig\nconst a = 1;\n```") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "| --- | --- |\n| `x\\|y` | \"ok\" |") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "{#") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[](") == null);
}

test "Markdown rejects unsupported source markup rather than leaking templates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m: Markdown = .{ .a = arena.allocator(), .base = "https://ziglang.org/documentation/0.17.0/", .version = pinned_version };
    try std.testing.expectError(error.InvalidOfficialSource, m.render("{#unknown|value#}"));
    try std.testing.expectError(error.InvalidOfficialSource, decodeEntities(arena.allocator(), "&unknown;"));
    try std.testing.expectError(error.InvalidOfficialSource, m.render("<pre>{#syntax#}unterminated</pre>"));
}

test "official source pin rejects compiler version and content drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const metadata: Metadata = .{
        .version = pinned_version,
        .source_archive = "https://ziglang.org/download/0.17.0/zig-0.17.0.tar.xz",
        .source_archive_sha256 = "b6c7f1728f043700d6529bac980800792f824256a9d2f1839b3d62beed0b8abd",
        .langref_path = "doc/langref.html.in",
        .langref_sha256 = "553503ea235fd96a3643e382b58c6240e60ce535e2bab0cce1e5c7cdd6f43c63",
        .builtin_registry_path = "lib/std/zig/BuiltinFn.zig",
        .builtin_registry_sha256 = "42062ec69edfac554be1add745ce70cb1e1323ff762bbe4b6c0e4a3d69533dcc",
        .build_zig_zon_path = "doc/build.zig.zon.md",
        .build_zig_zon_sha256 = "fb7e6da18d7eba76f2b79ed009c622ce19a5da3407fd592c4bb977a7de72dfcf",
        .documentation_url = "https://ziglang.org/documentation/0.17.0/",
        .license = "MIT",
    };
    try validateMetadata(arena.allocator(), metadata, pinned_version);
    try std.testing.expectError(error.InvalidOfficialSource, validateMetadata(arena.allocator(), metadata, "0.18.0"));
    try std.testing.expectError(error.InvalidOfficialSource, checkHash("modified source", metadata.langref_sha256, "language reference"));
    try std.testing.expectError(error.InvalidOfficialSource, parseDocuments(arena.allocator(), "{#header_open|@sizeOf#}<pre>{#syntax#}@sizeOf(comptime T: type) comptime_int{#endsyntax#}</pre><p>Returns size.</p>{#header_close#}", metadata));
}

test "official reference keeps generic signature arity and renders concrete source constructs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const metadata = try std.json.parseFromSliceLeaky(Metadata, a, @embedFile("zig/metadata.json"), .{});
    const docs = try parseDocuments(a, @embedFile("zig/langref.html.in"), metadata);
    const union_doc = docs.get("@Union").?;
    try std.testing.expectEqual(@as(usize, 5), union_doc.signature.parameters.len);
    try std.testing.expectEqualStrings("comptime ArgType: ?type", union_doc.signature.parameters[1]);
    try std.testing.expect(std.mem.indexOf(u8, union_doc.signature.label, "///") == null);
    const error_doc = docs.get("@errorFromInt").?;
    try std.testing.expectEqual(@as(usize, 1), error_doc.signature.parameters.len);
    try std.testing.expectEqualStrings("value: @Int(.unsigned, @bitSizeOf(anyerror))", error_doc.signature.parameters[0]);
    try std.testing.expect(std.mem.indexOf(u8, docs.get("@SpirvType").?.documentation, "| --- | --- | --- |") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs.get("@cmpxchgWeak").?.documentation, "```zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs.get("@call").?.documentation, "[lang.CallModifier struct.zig](https://ziglang.org/documentation/0.17.0/#call)") != null);
    try std.testing.expect(docs.get("@Frame") == null);
}
