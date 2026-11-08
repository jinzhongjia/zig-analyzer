//! Generates the test runner from the runner bundled with Zig:
//!
//! - The bundled runner records allocation stack traces for the testing allocator only in Debug,
//!   so under ReleaseSafe leak reports have no stack trace (which makes occasional leaks on CI
//!   impossible to track down). This adds a stack trace frame count to its allocator options.
//! - Tests that take at least `slow_seconds` are reported on stderr with their duration, so that
//!   slow tests on CI runners can be identified from the log.
//! - On aarch64 Darwin, stack traces are captured by walking the frame pointer chain instead of
//!   with the unwind info of the executable (see `frame_pointer_self_info`).
//!
//! Usage: patch_test_runner <input test_runner.zig> <output>; a patch whose anchor is not found is
//! left out (with a warning)

const std = @import("std");

const slow_seconds = 10;

/// Declarations added to the root of the test runner. `std.debug` takes `root.debug.SelfInfo` in
/// place of its own `SelfInfo`; this one finds symbols with the default implementation but reports
/// `can_unwind = false`, so that `std.debug.StackIterator` walks the frame pointer chain.
///
/// The testing allocator records a stack trace for every allocation and free. With the default
/// `SelfInfo` on Darwin, the standard library unwinds every frame with the unwind info of the
/// executable, which for most functions defers to DWARF: it runs their CFI again each time (no
/// cache, unlike on ELF) while holding a mutex shared by all threads, and the memory it allocates
/// for that is never reused. In Debug that made unwinding most of the run time of the tests on
/// macOS (see docs/zig-macos-stack-unwinding.md).
///
/// On aarch64 Darwin the ABI requires the frame pointer to address a valid frame record, and the
/// standard library itself rates frame pointer unwinding safe there when the code keeps frame
/// pointers (build.zig keeps them for the tests). The walk finds the same return addresses as the
/// unwind info, except that it misses the caller of a function that has no frame record at that
/// point; only a stack trace from a signal context (a crash) can start in such a function. On
/// other targets the standard library does not rate frame pointer unwinding safe, and the default
/// `SelfInfo` is kept.
const frame_pointer_self_info =
    \\pub const debug = struct {
    \\    pub const SelfInfo = if (builtin.cpu.arch == .aarch64 and builtin.os.tag.isDarwin() and !builtin.omit_frame_pointer)
    \\        FramePointerSelfInfo
    \\    else
    \\        std.debug.TargetInfo(builtin.os.tag, builtin.cpu.arch);
    \\};
    \\const FramePointerSelfInfo = struct {
    \\    inner: Inner,
    \\    const Inner = std.debug.TargetInfo(builtin.os.tag, builtin.cpu.arch);
    \\    const Error = std.debug.SelfInfoError;
    \\    pub const init: FramePointerSelfInfo = .{ .inner = .init };
    \\    pub const can_unwind = false;
    \\    pub fn deinit(si: *FramePointerSelfInfo, io: std.Io) void {
    \\        si.inner.deinit(io);
    \\    }
    \\    pub fn getSymbols(si: *FramePointerSelfInfo, io: std.Io, symbol_allocator: std.mem.Allocator, text_arena: std.mem.Allocator, address: usize, resolve_inline_callers: bool, symbols: *std.ArrayList(std.debug.Symbol)) Error!void {
    \\        return si.inner.getSymbols(io, symbol_allocator, text_arena, address, resolve_inline_callers, symbols);
    \\    }
    \\    pub fn getModuleName(si: *FramePointerSelfInfo, io: std.Io, address: usize) Error![]const u8 {
    \\        return si.inner.getModuleName(io, address);
    \\    }
    \\    pub fn getModuleSlide(si: *FramePointerSelfInfo, io: std.Io, address: usize) Error!usize {
    \\        return si.inner.getModuleSlide(io, address);
    \\    }
    \\};
    \\
;

const Patch = struct { anchor: []const u8, replacement: []const u8, what: []const u8 };

/// Applied independently of each other
const patches = [_]Patch{
    .{
        .anchor = ".check_write_after_free = true,",
        .replacement = ".check_write_after_free = true, .stack_trace_frames = 12,",
        .what = "stack traces of leaks stay disabled",
    },
    .{
        .anchor = "pub const std_options: std.Options = .{",
        .replacement = frame_pointer_self_info ++ "pub const std_options: std.Options = .{",
        .what = "stack traces on aarch64 Darwin are unwound with the unwind info (slow)",
    },
};

/// The two parts of the slow test report: applied only together
const timing_patches = [_]Patch{
    .{
        .anchor = "try server.serveStringMessage(.test_started, &.{});",
        .replacement = "try server.serveStringMessage(.test_started, &.{});\n" ++
            "                const za_test_start = std.Io.Clock.awake.now(testing.io);",
        .what = "slow tests are not reported",
    },
    .{
        .anchor = "testing.io_instance.deinit();\n                const leak_count",
        .replacement = std.fmt.comptimePrint(
            \\{{
            \\                    const za_elapsed = za_test_start.durationTo(std.Io.Clock.awake.now(testing.io)).toSeconds();
            \\                    if (za_elapsed >= {d}) std.debug.print("slow test ({{d}}s): {{s}}\n", .{{ za_elapsed, test_fn.name }});
            \\                }}
            \\                testing.io_instance.deinit();
            \\                const leak_count
        , .{slow_seconds}),
        .what = "slow tests are not reported",
    },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const a = init.arena.allocator();
    var text: []const u8 = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .unlimited);
    for (patches) |p| text = try apply(a, text, p);
    const timing = for (timing_patches) |p| {
        if (std.mem.indexOf(u8, text, p.anchor) == null) break false;
    } else true;
    if (timing) {
        for (timing_patches) |p| text = try apply(a, text, p);
    } else std.log.warn("test runner code not found, {s}", .{timing_patches[0].what});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = text });
}

fn apply(a: std.mem.Allocator, text: []const u8, p: Patch) ![]const u8 {
    const patched = try std.mem.replaceOwned(u8, a, text, p.anchor, p.replacement);
    if (std.mem.eql(u8, patched, text)) std.log.warn("test runner code not found, {s}", .{p.what});
    return patched;
}
