//! Adds the section of a new version to CHANGELOG.md, from the pull requests merged into HEAD since
//! the last release that is not a pre-release.
//!
//! Usage: zig build changelog -- <version>    (e.g. 0.2.0 or 0.2.0-rc.1, without the `v`)
//!
//! Each pull request is one line, `- <title> (#<number>)`, under the section its labels select:
//! `breaking`, `enhancement`, `bug`, `performance`; one with `internal` is left out, and one with
//! none of these goes under "Other changes". The titles are the starting point: edit the lines into
//! user-facing text before committing. Needs git and an authenticated gh in PATH.
//!
//! Pre-releases count from the last final release too, so the section of `0.2.0-rc.2` repeats what
//! `0.2.0-rc.1` listed. A final version replaces the sections of its pre-releases (`0.2.0-rc.N`):
//! its own section lists everything since the previous final release.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Category = enum { breaking, features, fixes, performance, other };

const headings = std.enums.EnumArray(Category, []const u8).init(.{
    .breaking = "Breaking changes",
    .features = "Features",
    .fixes = "Fixes",
    .performance = "Performance",
    .other = "Other changes",
});

const PullRequest = struct {
    title: []const u8,
    labels: []const struct { name: []const u8 },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: {s} <version>\n", .{args[0]});
        return 2;
    }
    const version = args[1];

    const root = trim(try run(arena, io, .inherit, &.{ "git", "rev-parse", "--show-toplevel" }) orelse return 1);
    const cwd: std.process.Child.Cwd = .{ .path = root };
    const repo_url = trim(try run(arena, io, cwd, &.{ "gh", "repo", "view", "--json", "url", "-q", ".url" }) orelse return 1);
    const path = try std.fs.path.join(arena, &.{ root, "CHANGELOG.md" });
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);

    const own_heading = try std.fmt.allocPrint(arena, "## [{s}](", .{version});
    if (std.mem.indexOf(u8, text, own_heading) != null) {
        std.debug.print("error: CHANGELOG.md already has a section for {s}\n", .{version});
        return 1;
    }

    // The previous final release; without one, the whole history
    const prev = try runOptional(arena, io, cwd, &.{ "git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "--exclude", "v*-*", "HEAD" });
    const range = if (prev) |p| try std.fmt.allocPrint(arena, "{s}..HEAD", .{trim(p)}) else "HEAD";

    // Merge commits on the first-parent chain name their pull requests
    const log = try run(arena, io, cwd, &.{ "git", "log", "--first-parent", "--format=%s", range }) orelse return 1;
    var items: std.enums.EnumArray(Category, std.ArrayList(u8)) = .initFill(.empty);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const n = pullRequestNumber(trim(line)) orelse continue;
        count += 1;
        const out = try run(arena, io, cwd, &.{ "gh", "pr", "view", n, "--json", "title,labels" }) orelse return 1;
        const pr = try std.json.parseFromSliceLeaky(PullRequest, arena, out, .{ .ignore_unknown_fields = true });
        const category = categorize(pr) orelse continue;
        try items.getPtr(category).print(arena, "- {s} ([#{s}]({s}/pull/{s}))\n", .{ pr.title, n, repo_url, n });
    }

    const day = std.time.epoch.EpochSeconds{ .secs = @intCast(Io.Clock.real.now(io).toSeconds()) };
    const year_day = day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var section: std.ArrayList(u8) = .empty;
    try section.print(arena, "## [{s}]({s}/releases/tag/v{s}) - {d}-{d:0>2}-{d:0>2}\n", .{
        version,       repo_url,                  version,
        year_day.year, month_day.month.numeric(), month_day.day_index + 1,
    });
    for (std.enums.values(Category)) |category| {
        const list = items.get(category);
        if (list.items.len == 0) continue;
        try section.print(arena, "\n### {s}\n\n{s}", .{ headings.get(category), list.items });
    }

    // The new section goes before the first version section, after the introduction; a final
    // version drops the sections of its pre-releases
    const drop: ?[]const u8 = if (std.mem.indexOfScalar(u8, version, '-') == null)
        try std.fmt.allocPrint(arena, "## [{s}-", .{version})
    else
        null;
    var result: std.ArrayList(u8) = .empty;
    var inserted = false;
    var skip = false;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "## [")) {
            skip = if (drop) |d| std.mem.startsWith(u8, line, d) else false;
            if (!inserted) {
                try result.print(arena, "{s}\n", .{section.items});
                inserted = true;
            }
        }
        if (!skip) try result.print(arena, "{s}\n", .{line});
    }
    if (!inserted) try result.print(arena, "\n{s}", .{section.items});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = result.items });

    std.debug.print("added the section of {s} to CHANGELOG.md ({d} pull requests since {s})\n", .{
        version, count, if (prev) |p| trim(p) else "the first commit",
    });
    return 0;
}

/// `Merge pull request #N from ...` or a squash-merged `<title> (#N)`
fn pullRequestNumber(subject: []const u8) ?[]const u8 {
    const prefix = "Merge pull request #";
    if (std.mem.startsWith(u8, subject, prefix)) {
        const rest = subject[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return digits(rest[0..end]);
    }
    if (std.mem.endsWith(u8, subject, ")")) {
        const start = std.mem.lastIndexOf(u8, subject, "(#") orelse return null;
        return digits(subject[start + 2 .. subject.len - 1]);
    }
    return null;
}

fn digits(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return s;
}

/// The section of a pull request, or null for an internal one
fn categorize(pr: PullRequest) ?Category {
    const has = struct {
        fn f(labels: @TypeOf(pr.labels), name: []const u8) bool {
            for (labels) |l| if (std.mem.eql(u8, l.name, name)) return true;
            return false;
        }
    }.f;
    if (has(pr.labels, "internal")) return null;
    if (has(pr.labels, "breaking")) return .breaking;
    if (has(pr.labels, "enhancement")) return .features;
    if (has(pr.labels, "bug")) return .fixes;
    if (has(pr.labels, "performance")) return .performance;
    return .other;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// The standard output of a command that must succeed; on failure its error output is shown and
/// the result is null
fn run(arena: Allocator, io: Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !?[]const u8 {
    const result = try std.process.run(arena, io, .{ .argv = argv, .cwd = cwd });
    if (result.term.success()) return result.stdout;
    std.debug.print("error: `{s}` failed:\n{s}", .{ try std.mem.join(arena, " ", argv), result.stderr });
    return null;
}

/// The standard output of a command, or null when it fails
fn runOptional(arena: Allocator, io: Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !?[]const u8 {
    const result = try std.process.run(arena, io, .{ .argv = argv, .cwd = cwd });
    return if (result.term.success()) result.stdout else null;
}

test pullRequestNumber {
    try std.testing.expectEqualStrings("313", pullRequestNumber("Merge pull request #313 from jinzhongjia/changelog-prereleases").?);
    try std.testing.expectEqualStrings("42", pullRequestNumber("fix: hover on fields (#42)").?);
    try std.testing.expect(pullRequestNumber("release: v0.1.1-rc.1") == null);
    try std.testing.expect(pullRequestNumber("note (#abc)") == null);
}
