//! Checks that the syntax-layer values rebuilt incrementally after a reparse equal those built
//! from scratch on the same tree (the parser property tests and `zig build corpus` use it). It
//! advances the values the way their queries do, including keeping the previous value when the
//! new one is equal (early cutoff).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parse = @import("Parse.zig");
const ItemTree = @import("ItemTree.zig");
const FileIndex = @import("FileIndex.zig");
const queries = @import("queries.zig");
const Summaries = queries.ItemSummaries.Summaries;
const Strings = FileIndex.ImportStrings.Strings;

pub const Derived = struct {
    parse: *Parse,
    tree: *ItemTree,
    map: ItemTree.AstIdMap,
    summaries: *Summaries,
    imports: *Strings,

    pub fn init(gpa: Allocator, parse: *Parse) Allocator.Error!Derived {
        const tree = try gpa.create(ItemTree);
        tree.* = try ItemTree.build(gpa, parse.rootNode(), parse.mode);
        tree.basis.store(parse.id, .monotonic);
        const map = try ItemTree.AstIdMap.build(gpa, tree, parse.rootNode());
        const summaries = try queries.ItemSummaries.build(gpa, tree, &map, null);
        summaries.basis.store(parse.id, .monotonic);
        const imports = try FileIndex.ImportStrings.collect(gpa, parse.rootNode(), null);
        imports.basis.store(parse.id, .monotonic);
        return .{ .parse = parse.retain(), .tree = tree, .map = map, .summaries = summaries, .imports = imports };
    }

    pub fn deinit(d: *Derived, gpa: Allocator) void {
        d.tree.deinit(gpa);
        gpa.destroy(d.tree);
        d.map.deinit(gpa);
        var s: queries.ItemSummaries.Value = d.summaries;
        queries.ItemSummaries.deinit(&s, gpa);
        var i: FileIndex.ImportStrings.Value = d.imports;
        FileIndex.ImportStrings.deinit(&i, gpa);
        d.parse.destroy();
    }

    /// Rebuilds the values for `new` (a reparse of the previous result) incrementally and from
    /// scratch; returns whether they agree. The incremental values replace the old ones
    pub fn advance(d: *Derived, gpa: Allocator, new: *Parse) Allocator.Error!bool {
        const root = new.rootNode();
        var same = true;

        // ItemTree
        var full_tree = try ItemTree.build(gpa, root, new.mode);
        defer full_tree.deinit(gpa);
        const tree = try gpa.create(ItemTree);
        tree.* = if (new.mode == .zig) if (new.inChain(d.tree.basis.load(.monotonic))) |old|
            try ItemTree.buildIncremental(gpa, root, d.tree, old.rootNode())
        else
            try ItemTree.build(gpa, root, .zig) else try ItemTree.build(gpa, root, new.mode);
        tree.basis.store(new.id, .monotonic);
        if (!tree.eql(&full_tree) or !std.mem.eql(u64, tree.item_ids, full_tree.item_ids) or !std.mem.eql(u64, tree.container_ids, full_tree.container_ids)) {
            std.debug.print("ItemTree differs\n", .{});
            same = false;
        }
        if (d.tree.eql(tree)) {
            d.tree.basis.store(new.id, .monotonic);
            tree.deinit(gpa);
            gpa.destroy(tree);
        } else {
            d.tree.deinit(gpa);
            gpa.destroy(d.tree);
            d.tree = tree;
        }

        // AstIdMap
        var full_map = try ItemTree.AstIdMap.build(gpa, d.tree, root);
        defer full_map.deinit(gpa);
        const map = try ItemTree.AstIdMap.buildIncremental(gpa, d.tree, root, &d.map);
        if (!mapEql(&map, &full_map, d.tree)) {
            std.debug.print("AstIdMap differs\n", .{});
            same = false;
        }
        d.map.deinit(gpa);
        d.map = map;

        // ItemSummaries
        const full_summaries = try queries.ItemSummaries.build(gpa, d.tree, &d.map, null);
        defer {
            var v: queries.ItemSummaries.Value = full_summaries;
            queries.ItemSummaries.deinit(&v, gpa);
        }
        const old_s: ?*const Parse = new.inChain(d.summaries.basis.load(.monotonic));
        const summaries = try queries.ItemSummaries.build(gpa, d.tree, &d.map, if (old_s) |o| .{ .prev = d.summaries, .old_root = o.rootNode() } else null);
        summaries.basis.store(new.id, .monotonic);
        if (!queries.ItemSummaries.eql(summaries, full_summaries) or !std.mem.eql(u32, summaries.top_item_ends, full_summaries.top_item_ends)) {
            std.debug.print("ItemSummaries differ: {d} items, tops {any} / {any}, reuse {}\n", .{ summaries.items.len, summaries.top_item_ends, full_summaries.top_item_ends, old_s != null });
            for (summaries.items, full_summaries.items, 0..) |x, y, i| if (!std.meta.eql(x, y)) std.debug.print("  item {d}: {any}\n  vs {any}\n", .{ i, x, y });
            if (!std.mem.eql(?u32, summaries.container_offsets, full_summaries.container_offsets)) std.debug.print("  containers {any} / {any}\n", .{ summaries.container_offsets, full_summaries.container_offsets });
            same = false;
        }
        {
            var drop: queries.ItemSummaries.Value = summaries;
            if (queries.ItemSummaries.eql(d.summaries, summaries) and std.mem.eql(u32, d.summaries.top_item_ends, summaries.top_item_ends)) {
                d.summaries.basis.store(new.id, .monotonic);
            } else {
                drop = d.summaries;
                d.summaries = summaries;
            }
            queries.ItemSummaries.deinit(&drop, gpa);
        }

        // ImportStrings
        const full_imports = try FileIndex.ImportStrings.collect(gpa, root, null);
        defer {
            var v: FileIndex.ImportStrings.Value = full_imports;
            FileIndex.ImportStrings.deinit(&v, gpa);
        }
        const old_i: ?*const Parse = new.inChain(d.imports.basis.load(.monotonic));
        const imports = try FileIndex.ImportStrings.collect(gpa, root, if (old_i) |o| .{ .prev = d.imports, .old_root = o.rootNode() } else null);
        imports.basis.store(new.id, .monotonic);
        if (!FileIndex.ImportStrings.eql(imports, full_imports) or !std.mem.eql(u32, imports.node_ends, full_imports.node_ends)) {
            std.debug.print("ImportStrings differ\n", .{});
            same = false;
        }
        {
            var drop: FileIndex.ImportStrings.Value = imports;
            if (FileIndex.ImportStrings.eql(d.imports, imports) and std.mem.eql(u32, d.imports.node_ends, imports.node_ends)) {
                d.imports.basis.store(new.id, .monotonic);
            } else {
                drop = d.imports;
                d.imports = imports;
            }
            FileIndex.ImportStrings.deinit(&drop, gpa);
        }

        d.parse.destroy();
        d.parse = new.retain();
        return same;
    }

    fn mapEql(a: *const ItemTree.AstIdMap, b: *const ItemTree.AstIdMap, tree: *const ItemTree) bool {
        if (!std.mem.eql(u32, a.top_item_ends, b.top_item_ends) or !std.mem.eql(u32, a.top_container_ends, b.top_container_ends)) return false;
        if (a.items.len != b.items.len or a.containers.len != b.containers.len) return false;
        for (a.items, b.items) |x, y| if (x.green != y.green or x.offset != y.offset) return false;
        for (a.containers, b.containers) |x, y| if (x.green != y.green or x.offset != y.offset) return false;
        for (tree.items) |it| if (!nodeEql(a.get(it.ast_id), b.get(it.ast_id))) return false;
        for (tree.containers) |c| if (!nodeEql(a.get(c.ast_id), b.get(c.ast_id))) return false;
        return true;
    }

    fn nodeEql(x: anytype, y: anytype) bool {
        if (x == null or y == null) return x == null and y == null;
        return x.?.green == y.?.green and x.?.offset == y.?.offset;
    }
};
