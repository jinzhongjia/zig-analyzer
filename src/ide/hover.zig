//! hover: signature, type, and documentation of the name at the cursor; the official documentation
//! of field names in `build.zig.zon`.

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ast = @import("../syntax/ast.zig");
const definition = @import("definition.zig");
const context = @import("context.zig");
const render = @import("../sema/render.zig");
const queries = @import("../sema/queries.zig");
const eval = @import("../sema/eval.zig");
const InternPool = @import("../sema/InternPool.zig");
const TypedValue = InternPool.TypedValue;
const Index = InternPool.Index;
const infer = @import("../sema/infer.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const Body = @import("../hir/Body.zig");
const seed = @import("../ide_db/seed.zig");
const builtins = @import("builtins.zig");
const manifest = @import("manifest.zig");
const project_config = @import("project_config.zig");

pub const Info = struct {
    /// markdown
    text: []const u8,
    start: u32,
    end: u32,
};

/// How hover shows the declarations that a member name refers to under the other instances of the
/// generic function containing it, when they differ from the one shown (see
/// `definition.instanceDefsAt`), and the other values of a binding or expression in a `defer` body
/// at the other exits that run it (see `exitValues`)
pub const Instances = enum {
    /// Only how many there are; goto lists the declarations
    count,
    /// The location and complete hover of each declaration, the complete hover of each value
    full,
};

/// Turns the source locations hover names (`inferred from the call at main.zig:4`) into links to
/// the line: `uri` gives the URI of a file as the client knows it
pub const Links = struct {
    ctx: *anyopaque,
    uri: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, file: FileId) std.mem.Allocator.Error![]const u8,
};

pub const Options = struct {
    /// The workspace folders: the paths of embedded files are shown relative to them (see
    /// `Vfs.shownPath`)
    roots: []const []const u8 = &.{},
    instances: Instances = .count,
    /// Show the size and alignment of a type value, and the offset of a struct field, when the
    /// layout is fully known
    layout: bool = true,
    /// Show the compiler's fully qualified name of a container-level declaration after its
    /// signature (`fqn: main.Wide`)
    fqn: bool = false,
    /// Null: locations are plain text
    links: ?Links = null,
};

/// `roots`: the workspace folders, the paths of embedded files are shown relative to them (see
/// `Vfs.shownPath`)
pub fn hover(r: *Resolver, file: FileId, offset: u32, roots: []const []const u8, instances: Instances) resolve.Error!?Info {
    return hoverWith(r, file, offset, .{ .roots = roots, .instances = instances });
}

pub fn hoverWith(r: *Resolver, file: FileId, offset: u32, opts: Options) resolve.Error!?Info {
    const tok = try definition.tokenAt(r, file, offset) orelse return null;
    if (tok.kind == .string_literal) return null;
    if (tok.kind == .builtin) {
        const entry = builtins.get(tok.text) orelse return null;
        var out: std.Io.Writer.Allocating = .init(r.arena);
        const w = &out.writer;
        if (entry.signature) |signature| w.print("```zig\n{s}\n```\n\n", .{signature}) catch return error.OutOfMemory;
        const doc = builtins.documentation(entry, try r.ctx.get(@import("../database.zig").syntax.SyntaxDialect, {}));
        w.writeAll(doc) catch return error.OutOfMemory;
        if (try semanticHover(r, file, offset, tok, opts)) |inferred| {
            w.print("\n\nInferred result:\n\n{s}", .{inferred.text}) catch return error.OutOfMemory;
        }
        return .{ .text = out.written(), .start = tok.offset, .end = tok.range().end };
    }
    if (try manifest.fieldDoc(r, file, tok)) |doc| return .{ .text = doc, .start = tok.offset, .end = tok.range().end };
    if (try project_config.fieldDoc(r, file, tok)) |doc| return .{ .text = doc, .start = tok.offset, .end = tok.range().end };
    return semanticHover(r, file, offset, tok, opts);
}

fn semanticHover(r: *Resolver, file: FileId, offset: u32, tok: ast.SyntaxToken, opts: Options) resolve.Error!?Info {
    const a = try context.at(r, file, tok.offset, false) orelse return null;
    const b = a.body;

    var def: ?Def = null;
    var tv: TypedValue = .unknown;
    // The binding or expression tv comes from (the same position is used when re-inferring with a
    // call-site instance)
    var binding_id: ?Body.BindingId = null;
    var expr_id: ?Body.ExprId = null;
    if (ast.memberName(a.node, try r.inEnum(file, a.item))) |name| if (name.offset == tok.offset) {
        // decltest: the name refers to the declaration it references, not to the test itself
        if (a.node.kind() == .test_decl and name.kind == .identifier) {
            def = try r.resolveContainerName(file, a.item, try ast.identNameAlloc(r.arena, name.text));
            if (def) |d| tv = try queries.defType(r, d, null, null);
        } else {
            def = .{ .item = .{ .file = file, .item = a.item } };
            tv = try r.ctx.get(queries.DeclType, .{ .owner = a.owner });
        }
    };
    if (def == null) if (b.bindingAt(tok.offset - a.node.offset)) |id| {
        def = .{ .local = .{ .file = file, .item = a.item, .binding = id } };
        tv = a.bindingType(id);
        binding_id = id;
    };
    if (def == null) {
        const e = b.exprAt(tok.offset - a.node.offset) orelse return null;
        // The reference's own value: a result type coercion (`take(a)` with a `?u8` parameter)
        // does not change what the name or member is
        tv = a.uncoercedType(e);
        expr_id = e;
        switch (b.expr(e)) {
            .name_ref => |name| {
                if (!Body.nameRefIsBuiltin(b, e)) def = try r.resolveName(file, a.item, b, b.expr_scopes[@backingInt(e)], name);
            },
            .field_access, .enum_literal => if (a.member(e)) |key| {
                def = try context.defOfKey(r, key);
            } else if (b.expr(e) == .field_access) {
                def = try definition.defAt(r, file, offset);
            },
            .builtin_call => {},
            .init => return initFieldHover(r, file, tok, e, opts),
            .error_value => |name| return errorValue(r, file, tok, e, name),
            else => return null,
        }
    }

    // A generic function body has no concrete instance: infer with a call-site instance
    const ip = r.ctx.db.env.ip;
    // An enum literal whose expected type contains parameters (`return .empty` in a function
    // returning `T`) names a declaration or tag only under an instance
    const instance_literal = def == null and expr_id != null and b.expr(expr_id.?) == .enum_literal and
        if (a.literalExpected(expr_id.?)) |t| seed.wanted(ip, .{ .ty = t }) else false;
    var seeded_from: ?seed.Seed = null;
    if ((binding_id != null or expr_id != null) and (instance_literal or seed.wanted(ip, tv))) {
        const subject: seed.Subject = if (binding_id) |id| .{ .binding = id } else .{ .expr = expr_id.? };
        const rel = tok.offset - a.node.offset;
        var refiner = try seed.Refiner.init(r, file, a.item, a.node.offset, b, a.res);
        if (try refiner.at(rel, subject)) |s| {
            const res = s.res;
            const better: TypedValue = if (binding_id) |id|
                (if (@backingInt(id) < res.bindings.len) res.bindings[@backingInt(id)] else .unknown)
            else
                res.uncoercedValue(expr_id.?);
            if (!seed.wanted(ip, better)) {
                tv = better;
                seeded_from = s;
                if (instance_literal) {
                    const i = @backingInt(expr_id.?);
                    if (i < res.members.len) if (res.members[i]) |key| {
                        def = try context.defOfKey(r, key);
                    };
                }
            }
        }
    }

    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    // In a defer body analyzed once per exit, the value at one exit, followed by the others
    const exits = try exitValues(r, a, def, binding_id, expr_id, seeded_from);
    var others: []const ExitValue = &.{};
    // The declarations shown with the exits, which `writeOtherInstances` must not show again
    var shown_at_exits: []const Def = &.{};
    // One value at every exit that the abstract inference already shows needs no exit
    if (exits.len > 1 or (exits.len == 1 and (exits[0].tv.ty != tv.ty or exits[0].tv.val != tv.val))) {
        const first = for (exits, 0..) |x, k| {
            if (seeded_from) |s| if (sameInstance(s, x.seed)) break k;
        } else 0;
        def = exits[first].def;
        tv = exits[first].tv;
        seeded_from = exits[first].seed;
        var rest: std.ArrayList(ExitValue) = .empty;
        for (exits, 0..) |x, k| if (k != first) try rest.append(r.arena, x);
        others = rest.items;
        var shown: std.ArrayList(Def) = .empty;
        for (exits) |x| if (x.def) |d| try shown.append(r.arena, d);
        shown_at_exits = shown.items;
    }
    if (!try writeBlock(w, r, a, def, tv, expr_id, seeded_from, false, opts)) return null;
    if (others.len > 0) switch (opts.instances) {
        .count => w.print("\n\nTakes {d} other value{s} at other exits of the block", .{ others.len, if (others.len == 1) "" else "s" }) catch return error.OutOfMemory,
        .full => for (others) |x| {
            w.writeAll("\n\n---\n\n") catch return error.OutOfMemory;
            _ = try writeBlock(w, r, a, x.def, x.tv, expr_id, x.seed, false, opts);
        },
    };
    if (expr_id) |e| switch (b.expr(e)) {
        .field_access, .enum_literal => try writeOtherInstances(w, r, def, seeded_from, shown_at_exits, try definition.instanceDefsAt(r, file, offset), .{ .expr = e }, opts),
        else => {},
    };
    return .{ .text = out.written(), .start = tok.offset, .end = tok.offset + @as(u32, @intCast(tok.text.len)) };
}

const ExitValue = struct {
    seed: seed.Seed,
    tv: TypedValue,
    /// The declaration the name refers to at this exit: what `context.defOfKey` gives for the
    /// member the exit's inference result resolves, not the abstract one; the binding's declaration
    /// elsewhere
    def: ?Def,
};

/// In a `defer` body that the compiler analyzes once per exit with different `comptime var`
/// values (see `seed.exitSeeds`), the value of the binding or expression at each exit, each
/// distinct value and declaration once with its first exit; empty elsewhere, and under a call-site
/// instance (`shown` is not an exit), whose exits are not inferred separately
fn exitValues(r: *Resolver, a: context.At, def: ?Def, binding_id: ?Body.BindingId, expr_id: ?Body.ExprId, shown: ?seed.Seed) resolve.Error![]const ExitValue {
    if (binding_id == null and expr_id == null) return &.{};
    if (shown) |s| if (s.exit == null) return &.{};
    // A member name can refer to a different declaration at each exit: its member comes from the
    // exit's inference result (`At.member` prefers the abstract result, which has none for a name
    // that only resolves under an exit)
    const member = expr_id != null and switch (a.body.expr(expr_id.?)) {
        .field_access, .enum_literal => true,
        else => false,
    };
    var out: std.ArrayList(ExitValue) = .empty;
    for (try seed.exitSeeds(r, a.file, a.item, a.body, a.res, a.rel)) |s| {
        const res = s.res;
        const at_exit: TypedValue = if (binding_id) |id|
            (if (@backingInt(id) < res.bindings.len) res.bindings[@backingInt(id)] else continue)
        else
            res.uncoercedValue(expr_id.?);
        if (at_exit.ty == .unknown) continue;
        const exit_def = if (member) blk: {
            const i = @backingInt(expr_id.?);
            const key = if (i < res.members.len) res.members[i] else null;
            break :blk if (key) |k| try context.defOfKey(r, k) else null;
        } else def;
        if (for (out.items) |x| {
            if (x.tv.ty == at_exit.ty and x.tv.val == at_exit.val and std.meta.eql(x.def, exit_def)) break true;
        } else false) continue;
        try out.append(r.arena, .{ .seed = s, .tv = at_exit, .def = exit_def });
    }
    return out.items;
}

/// The hover of `def`, or of the expression `e` when there is no definition, whose value is `tv`
/// at `a`: the signature or value, the embedded file it comes from, the instance it is inferred
/// under (`seeded`), preceded by the location of `def` when `located`, and the documentation. False
/// when there is nothing to show.
fn writeBlock(w: *std.Io.Writer, r: *Resolver, a: context.At, def: ?Def, tv: TypedValue, e: ?Body.ExprId, seeded: ?seed.Seed, located: bool, opts: Options) resolve.Error!bool {
    if (tv.ty == .unknown and def == null) return false;
    // A value that is directly the result of `@embedFile`: the call instead of the content
    const embed = if (def) |d| try context.embedOf(r, d, tv) else if (tv.val != null) try context.embedCall(r, a, e.?) else null;
    const code = if (def) |d|
        try context.signature(r, d, tv, .multi_line)
    else if (embed) |x|
        try render.embedAlloc(r, tv.ty, x.path)
    else
        try render.exprAlloc(r, tv);
    w.print("```zig\n{s}\n```", .{code}) catch return error.OutOfMemory;
    if (opts.layout) try writeLayout(w, r, a, def, tv, e);
    if (opts.fqn) if (def) |d| switch (d) {
        .item => |it| if (try render.declName(r, r.arena, it.file, it.item, defInstance(a, e, seeded))) |name|
            w.print("\n\nfqn: `{s}`", .{name}) catch return error.OutOfMemory,
        else => {},
    };
    if (embed) |x| writeEmbedded(w, r.ctx.db.env.vfs.shownPath(opts.roots, r.ctx.db.env.vfs.path(x.file)), x.text) catch return error.OutOfMemory;
    if (seeded) |s| {
        w.writeAll("\n\n") catch return error.OutOfMemory;
        if (located) if (try r.location(def.?)) |loc| {
            w.writeAll("at ") catch return error.OutOfMemory;
            try writeLocation(w, r, loc.file, loc.start, opts.links);
            w.writeAll(", ") catch return error.OutOfMemory;
        };
        w.writeAll("inferred from ") catch return error.OutOfMemory;
        try writeSource(w, r, s, opts.links);
    }
    if (def) |d| if (try context.docOf(r, d, tv)) |text| w.print("\n\n{s}", .{text}) catch return error.OutOfMemory;
    return true;
}

/// The instance of the container that declares the definition shown at `e`, when it is known: the
/// container type of a member access (`Gen(u16).Inner`, also through pointers and optionals), or
/// the call-site instance that the hover is inferred under (`seeded`)
fn defInstance(a: context.At, e: ?Body.ExprId, seeded: ?seed.Seed) ?Index {
    if (e) |x| switch (a.body.expr(x)) {
        .field_access => |fa| {
            // The type of the left-hand side under the instance the hover is inferred under
            var at = a;
            at.seeded = seeded;
            const tv = at.exprType(fa.lhs);
            var t = tv.asType() orelse tv.ty;
            while (true) {
                t = switch (a.ip.key(t)) {
                    .ptr_type => |p| p.child,
                    .optional_type => |c| c,
                    else => break,
                };
            }
            if (queries.instOfType(a.ip, t)) |inst| return inst;
        },
        else => {},
    };
    return if (seeded) |s| s.inst else null;
}

/// The size and alignment of the type `tv` when it is the value of a type, and the byte offset of
/// the struct field that `def` and `e` name, when the layout is fully known
fn writeLayout(w: *std.Io.Writer, r: *Resolver, a: context.At, def: ?Def, tv: TypedValue, e: ?Body.ExprId) resolve.Error!void {
    if (tv.asType()) |t| if (!isNamespace(r, t)) if (try eval.typeLayout(r, t)) |l|
        w.print("\n\nsize: {d} · align: {d}", .{ l.size, l.alignment }) catch return error.OutOfMemory;
    const d = def orelse return;
    const it = switch (d) {
        .item => |x| x,
        else => return,
    };
    const tree = try r.itemTree(it.file);
    const item = tree.items[it.item];
    // Only a field has an offset, not a declaration of the container
    if (item.kind != .field) return;
    const name = item.name orelse return;
    // The field's container: the type of the value on the left of the access, or the container
    // the field is declared in
    var container: ?Index = null;
    if (e) |x| switch (a.body.expr(x)) {
        .field_access => |f| container = a.exprType(f.lhs).asType(),
        else => {},
    };
    if (container == null) container = try queries.containerType(r, .{ .file = it.file, .container = item.container }, if (a.seeded) |s| s.inst else null);
    if (try fieldOffset(r, container, name)) |offset|
        w.print("\n\noffset: {d}", .{offset}) catch return error.OutOfMemory;
}

/// A file is a struct type, but a module is not a value with a size to show
fn isNamespace(r: *Resolver, t: Index) bool {
    return switch (r.ctx.db.env.ip.key(t)) {
        .container_type => |c| c.kind == .file,
        else => false,
    };
}

/// Byte offset of the field `name` of `base` (following a single pointer, which a field access
/// dereferences), when it is a non-packed struct whose layout is fully known; null for comptime
/// fields and packed structs, whose offset is a bit offset
fn fieldOffset(r: *Resolver, base: ?Index, name: []const u8) resolve.Error!?u64 {
    var t = base orelse return null;
    const ip = r.ctx.db.env.ip;
    // A field access follows a single-item or C pointer
    switch (ip.key(t)) {
        .ptr_type => |p| {
            if (p.size == .one or p.size == .c) t = p.child;
        },
        else => {},
    }
    const layout = (try eval.containerLayout(r, t)) orelse return null;
    if (layout == .@"packed") return null;
    const bits = try eval.bitOffsetOf(r, t, name) orelse return null;
    return bits / 8;
}

/// Where the instance `s` comes from: `the call at file.zig:12`, or the iteration of each loop
/// and the exit of each `defer` body containing the position, outermost first
fn writeSource(w: *std.Io.Writer, r: *Resolver, s: seed.Seed, links: ?Links) resolve.Error!void {
    const n = s.iteration orelse {
        w.writeAll("the call at ") catch return error.OutOfMemory;
        return writeLocation(w, r, s.file, s.offset, links);
    };
    for (s.enclosing, 0..) |outer, i| {
        try writeStep(w, r, s.file, outer, links);
        w.writeAll(if (i + 1 < s.enclosing.len) ", " else " and ") catch return error.OutOfMemory;
    }
    try writeStep(w, r, s.file, .{ .offset = s.offset, .iteration = n, .exit = s.exit }, links);
}

/// `iteration 2 of the loop at file.zig:12`, `the exit at file.zig:12` or `the end of the block
/// at file.zig:12`; an exit inside unrolled loops adds the iterations that reach it
/// (`the exit at file.zig:13 in iteration 2 of the loop at file.zig:12`)
fn writeStep(w: *std.Io.Writer, r: *Resolver, file: FileId, step: seed.Seed.LoopIteration, links: ?Links) resolve.Error!void {
    if (step.exit) |x| {
        w.print("{s} at ", .{if (x.fall_through) "the end of the block" else "the exit"}) catch return error.OutOfMemory;
        try writeLocation(w, r, file, step.offset, links);
        for (x.iterations, 0..) |it, i| {
            w.writeAll(if (i == 0) " in " else ", ") catch return error.OutOfMemory;
            try writeStep(w, r, file, it, links);
        }
        return;
    }
    w.print("iteration {d} of the loop at ", .{step.iteration + 1}) catch return error.OutOfMemory;
    try writeLocation(w, r, file, step.offset, links);
}

/// `file.zig:12`, the line of `offset` in `file`; with `links`, a link to that line
/// (`[file.zig:12](file:///p/file.zig#L12)`)
fn writeLocation(w: *std.Io.Writer, r: *Resolver, file: FileId, offset: u32, links: ?Links) resolve.Error!void {
    const text = (try r.ctx.get(@import("../database.zig").syntax.SourceText, file)).text;
    const line = std.mem.count(u8, text[0..@min(offset, text.len)], "\n") + 1;
    const name = std.fs.path.basename(r.ctx.db.env.vfs.path(file));
    if (links) |l| {
        const target = try l.uri(l.ctx, r.arena, file);
        w.print("[{s}:{d}]({s}#L{d})", .{ name, line, target, line }) catch return error.OutOfMemory;
    } else w.print("{s}:{d}", .{ name, line }) catch return error.OutOfMemory;
}

/// A member name in hover: the member of a member access or a decl literal (`expr`), or the
/// `k`-th field name of the initializer `e`
const Name = union(enum) {
    expr: Body.ExprId,
    init_field: struct { e: Body.ExprId, k: usize },
};

/// The type and value of the name under the instance of `a`
fn nameType(r: *Resolver, a: context.At, name: Name) resolve.Error!TypedValue {
    switch (name) {
        // The instance's own value: what `res` already settles is the same under every instance,
        // and a decl literal is settled there only as `@EnumLiteral()`
        .expr => |e| return if (a.seeded) |s| s.res.uncoercedValue(e) else a.uncoercedType(e),
        .init_field => |f| return .{ .ty = (try initFieldAt(r, instanceOnly(a), f.e, f.k)).ty orelse .unknown },
    }
}

/// Whether two instances are the same: the same instance at the same call site (and iteration)
fn sameInstance(x: seed.Seed, y: seed.Seed) bool {
    return x.inst == y.inst and x.file == y.file and x.offset == y.offset and x.iteration == y.iteration;
}

/// The declarations that the name refers to under the other instances of the generic function
/// containing it (`all`, see `definition.instanceDefsAt`), except the one shown (`shown`, or when
/// the hover shows no declaration (a decl literal shows its value), the one under the instance
/// the hover is inferred under (`shown_seed`)) and the ones already shown as the value at an exit
/// of a `defer` body (`shown_at_exits`). `.count` shows how many there are; `.full` shows each
/// once, with the first instance that refers to it, in the order goto lists them.
fn writeOtherInstances(w: *std.Io.Writer, r: *Resolver, shown: ?Def, shown_seed: ?seed.Seed, shown_at_exits: []const Def, all: []const definition.InstanceDef, name: Name, opts: Options) resolve.Error!void {
    var seen: std.ArrayList(Def) = .empty;
    for (shown_at_exits) |d| if (!containsDef(seen.items, d)) try seen.append(r.arena, d);
    if (shown) |d| {
        if (!containsDef(seen.items, d)) try seen.append(r.arena, d);
    } else if (shown_seed) |ss| for (all) |x| if (x.at.seeded) |s| if (sameInstance(s, ss)) {
        if (!containsDef(seen.items, x.def)) try seen.append(r.arena, x.def);
        break;
    };
    var others: usize = 0;
    for (all) |x| {
        const s = x.at.seeded orelse continue;
        if (containsDef(seen.items, x.def)) continue;
        try seen.append(r.arena, x.def);
        others += 1;
        if (opts.instances == .count) continue;
        w.writeAll("\n\n---\n\n") catch return error.OutOfMemory;
        const e = switch (name) {
            .expr => |e| e,
            .init_field => null,
        };
        _ = try writeBlock(w, r, x.at, x.def, try nameType(r, x.at, name), e, s, true, opts);
    }
    if (opts.instances == .count and others > 0) {
        w.print("\n\nRefers to {d} other declaration{s} under other instances; go to definition lists them", .{ others, if (others == 1) "" else "s" }) catch return error.OutOfMemory;
    }
}

/// Whether `defs` contains `d`
fn containsDef(defs: []const Def, d: Def) bool {
    for (defs) |x| if (std.meta.eql(x, d)) return true;
    return false;
}

/// The file a value comes from with `@embedFile` and its size; its content when it is text of at
/// most `render.max_value_length` characters
fn writeEmbedded(w: *std.Io.Writer, path: []const u8, content: []const u8) std.Io.Writer.Error!void {
    try w.print("\n\nEmbedded file `{s}`: {d} bytes", .{ path, content.len });
    if (!isShortText(content)) return;
    // The fence is longer than any run of backticks in the content
    var fence: usize = 3;
    var run: usize = 0;
    for (content) |c| {
        run = if (c == '`') run + 1 else 0;
        fence = @max(fence, run + 1);
    }
    try w.writeAll("\n\n");
    try w.splatByteAll('`', fence);
    try w.writeAll("text\n");
    try w.writeAll(content);
    if (content.len > 0 and content[content.len - 1] != '\n') try w.writeByte('\n');
    try w.splatByteAll('`', fence);
}

/// Valid UTF-8 of at most `render.max_value_length` code points, without control characters
/// other than tab, line feed and carriage return
fn isShortText(content: []const u8) bool {
    const view = std.unicode.Utf8View.init(content) catch return false;
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint()) |c| {
        count += 1;
        if (count > render.max_value_length) return false;
        switch (c) {
            '\t', '\n', '\r' => {},
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0x9f => return false,
            else => {},
        }
    }
    return true;
}

/// A field name in an initializer (`.{ .name = x }`, `T{ .name = x }`): the field of the
/// initializer's type, with its type in that type (the field type in the instance for a generic
/// container; inside a generic function body, in a call-site instance) and its documentation. A
/// field of a constructed type (`@Struct`, such as `std.enums.EnumFieldStruct`) has no
/// declaration: only its name and type.
fn initFieldHover(r: *Resolver, file: FileId, tok: ast.SyntaxToken, e: Body.ExprId, opts: Options) resolve.Error!?Info {
    const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
    const fields = a.body.expr(e).init.fields;
    const rel = tok.offset - a.node.offset;
    const k = for (fields, 0..) |f, k| {
        if (f.name != null and rel >= f.name_range.start and rel < f.name_range.end) break k;
    } else return null;
    var field = try initFieldAt(r, a, e, k);
    // The result type is a parameter (`.{ .len = 3 }` returned as `T`): the field exists only
    // under an instance. A result type that names the field (`Pair(T)`) keeps its type in terms
    // of the parameters.
    var from: ?seed.Seed = null;
    if (field.member == null) if (a.seeded) |s| {
        const under = try initFieldAt(r, instanceOnly(a), e, k);
        if (under.member != null) {
            field = under;
            from = s;
        }
    };
    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    // The result type is abstract when the field exists only under an instance
    const init_ty = if (opts.layout) (if (from != null) instanceOnly(a) else a).initType(e) else null;
    const member = field.member orelse {
        const ty = field.ty orelse return null;
        if (ty == .unknown) return null;
        w.print("```zig\n{f}: {s}\n```", .{ std.zig.fmtId(fields[k].name.?), try render.typeAlloc(r, ty) }) catch return error.OutOfMemory;
        if (opts.layout) if (try fieldOffset(r, init_ty, fields[k].name.?)) |offset| w.print("\n\noffset: {d}", .{offset}) catch return error.OutOfMemory;
        return .{ .text = out.written(), .start = tok.offset, .end = tok.range().end };
    };
    const def = try context.defOfKey(r, member) orelse return null;
    w.print("```zig\n{s}\n```", .{try context.signature(r, def, .{ .ty = field.ty orelse .unknown }, .multi_line)}) catch return error.OutOfMemory;
    if (opts.layout) if (try fieldOffset(r, init_ty, fields[k].name.?)) |offset| w.print("\n\noffset: {d}", .{offset}) catch return error.OutOfMemory;
    if (from) |s| {
        w.writeAll("\n\ninferred from ") catch return error.OutOfMemory;
        try writeSource(w, r, s, opts.links);
    }
    if (try context.doc(r, def)) |text| w.print("\n\n{s}", .{text}) catch return error.OutOfMemory;
    try writeOtherInstances(w, r, def, a.seeded, &.{}, try definition.instanceDefsAt(r, file, tok.offset), .{ .init_field = .{ .e = e, .k = k } }, opts);
    return .{ .text = out.written(), .start = tok.offset, .end = tok.range().end };
}

/// The field that the `k`-th field name of the initializer `e` names at `a`, with its type
fn initFieldAt(r: *Resolver, a: context.At, e: Body.ExprId, k: usize) resolve.Error!infer.InitField {
    const t = a.initType(e) orelse return .{};
    if (t == .unknown) return .{};
    return infer.initField(r, t, try queries.namespaceOfType(r, t), k, a.body.expr(e).init.fields[k].name);
}
/// `a` with only the inference result of its instance (`a.seeded`), not the abstract one
fn instanceOnly(a: context.At) context.At {
    var x = a;
    if (a.seeded) |s| {
        x.res = s.res;
        x.seeded = null;
    }
    return x;
}
/// `error.Foo`: the error name and the expected error set, plus its documentation when the
/// current file declares it
fn errorValue(r: *Resolver, file: FileId, tok: ast.SyntaxToken, e: Body.ExprId, name: []const u8) resolve.Error!?Info {
    if (name.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    if (try definition.expectedErrorSet(r, file, tok.offset, e)) |set| {
        w.print("```zig\nerror.{s}: {s}\n```", .{ name, try render.typeAlloc(r, set) }) catch return error.OutOfMemory;
    } else {
        w.print("```zig\nerror.{s}\n```", .{name}) catch return error.OutOfMemory;
    }
    if (try definition.errorValueDecl(r, file, tok.offset, false)) |d| if (d.doc) |doc| w.print("\n\n{s}", .{doc}) catch return error.OutOfMemory;
    return .{ .text = out.written(), .start = tok.offset, .end = tok.offset + @as(u32, @intCast(tok.text.len)) };
}
