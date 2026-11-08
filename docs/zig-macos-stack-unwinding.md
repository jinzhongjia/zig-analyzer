# Zig standard library stack unwinding on macOS

Recorded on 2026-11-08 for Zig 0.17.0 and 0.17.1, which are identical in every part described below. On aarch64 macOS, the standard library captures a stack trace by unwinding every frame with the unwind info of the executable, and reinterprets the DWARF CFI of most functions each time. The testing allocator records a stack trace for every allocation and free, so in Debug the tests spent most of their time unwinding, and the macOS Debug test jobs took 50-60 minutes, more than twice the Linux and Windows ones. The test runner works around it by unwinding with frame pointers on aarch64 Darwin (`tools/patch_test_runner.zig`).

## Symptoms

CI jobs of the same commit (`zig build test-all`, Zig 0.17.1), duration of the test step as reported by `--summary all`:

| Runner | Debug | ReleaseSafe |
|---|---|---|
| macOS (aarch64) | 50 min, MaxRSS 3 GB | 15 min, MaxRSS 3 GB |
| Linux (x86_64) | 21 min, MaxRSS 954 MB | 5 min, MaxRSS 958 MB |
| Windows (x86_64) | 20 min, MaxRSS 783 MB | 14-18 min, MaxRSS 766 MB |

In samples of the macOS Debug test binary (`server.auto_import_test`), 81-89% of the samples of the busy thread are in `std.debug.captureCurrentStackTrace` called by `heap.SafeAllocator`, and 64-68% in `Dwarf.SelfUnwinder.computeRules` below `SelfInfo.MachO.unwindFrame`; the other threads are idle.

## Cause

Line numbers refer to `lib/std` of Zig 0.17.1.

1. `StackIterator.init` (`debug.zig:954-988`) unwinds with `SelfInfo` whenever `SelfInfo.can_unwind` is true and frame pointer unwinding is not `.ideal` for the target. On aarch64 Darwin it is `.safe` (`debug.zig:1052`), so frame pointers are used only when unwinding with the unwind info fails. This is deliberate: since 0.16.0 the standard library prefers "safe" unwinding whenever it is available, considering the cost usually acceptable ([0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html#Debug-Information-Reworked)).
2. `SelfInfo/MachO.zig` unwinds one frame per call of `unwindFrameInner` (lines 165-461): it looks up the module (and locks `si.mutex` until the frame is unwound), searches `__unwind_info`, and for an entry in DWARF mode (lines 415-419) calls `Dwarf.SelfUnwinder.computeRules`, which finds the FDE and runs the CFI program up to the PC. Nothing is cached. `SelfInfo/Elf.zig` (lines 211-236) keeps the computed rules in a cache of 2048 entries keyed by PC, read under a shared lock, so on Linux a frame that was unwound before costs a lookup.
3. The binaries Zig builds for aarch64 macOS have asynchronous unwind tables (the FDEs also describe the epilogues), and almost every function has a DWARF mode entry in `__unwind_info`: 22714 of the 23219 entries (97.8%) of the Debug test binary of this repository. With `-funwind-tables` (synchronous tables) all entries are in FRAME mode, which the unwinder handles without DWARF; that makes an allocation benchmark 5-7 times faster, against 24-47 times with frame pointers.
4. The rules are computed with `std.debug.getDebugInfoAllocator()`, by default a global arena (`debug.zig:1500-1510`), so the memory of each computation is never reused: the resident memory grows with the number of captured stack traces (about 580 bytes per trace of 12 frames in ReleaseSafe), which accounts for most of the 3 GB MaxRSS of the macOS test steps.
5. In Debug, the unwinder itself is compiled in Debug, about 11 times slower than in ReleaseSafe.

The test runner of this repository records 12 frames per allocation (also in ReleaseSafe, so that leaks can be located there); the testing allocator records each stack trace when allocating and when freeing.

Measured on an Apple M-series machine with the program in [Reproduction](#reproduction) (100,000 stack traces of 12 frames each):

| Zig | Mode | Unwind info | Frame pointers |
|---|---|---|---|
| 0.17.0 | Debug | 2419 ms, RSS 35 MB | 70 ms, RSS 2.3 MB |
| 0.17.0 | ReleaseSafe | 189 ms, RSS 60 MB | 2 ms, RSS 1.8 MB |
| 0.17.1 | Debug | 2368 ms, RSS 35 MB | 82 ms, RSS 2.3 MB |
| 0.17.1 | ReleaseSafe | 208 ms, RSS 60 MB | 2 ms, RSS 1.8 MB |

With 1,000,000 stack traces (0.17.1, ReleaseSafe), unwinding with the unwind info takes 2.3 s and the resident memory reaches 578 MB.

## Workaround

`tools/patch_test_runner.zig` adds a `root.debug.SelfInfo` to the test runner. On aarch64 Darwin, when the code keeps frame pointers (build.zig keeps them for the tests), it looks up symbols and modules with the default `SelfInfo` but reports `can_unwind = false`, so that `StackIterator` walks the frame pointer chain. Everywhere else it is the default `SelfInfo`.

- Frame pointer unwinding is safe there: the Darwin arm64 ABI requires x29 to address a valid frame record at all times, and the standard library itself rates it `.safe` on this target.
- Stack traces of allocations are the same as with the unwind info. A test runner that unwound with the unwind info and compared every frame with the frame record (return address and frame pointer of the caller) found no difference over 212,994,059 frames (Debug `server.auto_import_test`, Zig 0.17.1), nor over the frames of an allocation benchmark in Debug and ReleaseSafe with Zig 0.17.0 and 0.17.1. A leak report of a test that leaks on the main thread and on a spawned thread lists the same frames as before, in Debug and ReleaseSafe.
- Cost: a stack trace from a signal context (a crash) misses the caller of the crashing function when that function has no frame record (a leaf function) or crashed before setting it up or after tearing it down; the unwind info would include it. Panics, failed assertions, and allocation stack traces start from a call and are not affected.
- The zig-analyzer executable is not affected; only test binaries use the patched runner.

Results in this repository, local on an Apple M-series machine, `zig build test-stress -Dstress-filter=auto_import_test -Dstress-runs=1` (Debug, 37 tests), test step as reported by `--summary all`, then the test binary run directly:

| Zig | Unwind info | Frame pointers |
|---|---|---|
| 0.17.0 | 14 min, MaxRSS 1 GB; 834 s, max RSS 1.9 GB | 2 min, MaxRSS 451 MB; 161 s, max RSS 380 MB |
| 0.17.1 | 14 min, MaxRSS 2 GB; 830 s, max RSS 2.4 GB | 2 min, MaxRSS 375 MB; 176 s, max RSS 458 MB |

With frame pointers, stack capture accounts for 0.5% of the samples; the busy threads mostly wait for the `zig build` processes of the tests.

## Reproduction

`repro.zig` captures 100,000 stack traces with the default `SelfInfo`; `repro_fp.zig` is the same program with the `SelfInfo` of the workaround.

```
zig build-exe repro.zig -O Debug && /usr/bin/time -l ./repro
zig build-exe repro_fp.zig -O Debug && /usr/bin/time -l ./repro_fp
```

```zig
// repro.zig
const std = @import("std");
const builtin = @import("builtin");

noinline fn capture(comptime depth: usize, buf: []usize) usize {
    if (depth == 0) return std.debug.captureCurrentStackTrace(.{}, buf).return_addresses.len;
    const n = capture(depth - 1, buf);
    std.mem.doNotOptimizeAway(depth);
    return n;
}

pub fn main(init: std.process.Init) void {
    var buf: [12]usize = undefined;
    const start = std.Io.Clock.awake.now(init.io);
    var frames: usize = 0;
    for (0..100_000) |_| frames += capture(16, &buf);
    const ms = start.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds();
    std.debug.print("100000 stack traces, {d} frames: {d} ms\n", .{ frames, ms });
}

/// The default `SelfInfo` with `can_unwind = false`, as in tools/patch_test_runner.zig
pub const fp_debug = struct {
    pub const SelfInfo = struct {
        inner: Inner,
        const Inner = std.debug.TargetInfo(builtin.os.tag, builtin.cpu.arch);
        const Error = std.debug.SelfInfoError;
        pub const init: SelfInfo = .{ .inner = .init };
        pub const can_unwind = false;
        pub fn deinit(si: *SelfInfo, io: std.Io) void {
            si.inner.deinit(io);
        }
        pub fn getSymbols(si: *SelfInfo, io: std.Io, symbol_allocator: std.mem.Allocator, text_arena: std.mem.Allocator, address: usize, resolve_inline_callers: bool, symbols: *std.ArrayList(std.debug.Symbol)) Error!void {
            return si.inner.getSymbols(io, symbol_allocator, text_arena, address, resolve_inline_callers, symbols);
        }
        pub fn getModuleName(si: *SelfInfo, io: std.Io, address: usize) Error![]const u8 {
            return si.inner.getModuleName(io, address);
        }
        pub fn getModuleSlide(si: *SelfInfo, io: std.Io, address: usize) Error!usize {
            return si.inner.getModuleSlide(io, address);
        }
    };
};
```

```zig
// repro_fp.zig
pub const debug = @import("repro.zig").fp_debug;
pub const main = @import("repro.zig").main;
```

## Upstream

- [ziglang/zig#36533](https://codeberg.org/ziglang/zig/issues/36533) (Codeberg, open as of 2026-11-08), "Severe Memory Leak on MacOS": memory grows while capturing allocation stack traces on macOS. The missing `StackIterator.deinit` it found was fixed by [ziglang/zig#36540](https://codeberg.org/ziglang/zig/pulls/36540), which 0.17.0 already includes; the global arena of point 4 is the remaining cause there. The speed of unwinding is not discussed.
- No upstream issue covers the speed (no rule cache in `SelfInfo/MachO.zig`, DWARF mode for most functions, or the choice of unwinding strategy on aarch64 Darwin). On the master branch as of 2026-11-08, `SelfInfo/MachO.zig` still has no cache and `StackIterator.init` still prefers the unwind info.
