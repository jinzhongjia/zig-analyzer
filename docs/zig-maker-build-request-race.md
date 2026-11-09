# Zig 0.17 maker panic after a build request

Recorded on 2026-11-09 for Zig 0.17.0 and 0.17.1, which have the same defect. While handling a `bsp_build_steps` request, the maker that `zig build --listen=-` runs (`lib/compiler/Maker.zig`) can close the event queue of its protocol loop. The build of that request completes, and the maker then panics with `attempt to unwrap error: Closed` instead of waiting for the next request. It happens more often with few cores and a busy CPU. The server restarts the maker when it exits (`Workspace.run`), so compiler diagnostics keep updating.

## Symptoms

Stderr of the maker:

```
thread 71 panic: attempt to unwrap error: Closed
Cannot print stack trace: stack tracing is disabled
```

- The panic is on the main thread of the maker (its thread id is the process id), after it has sent `bsp_build_completed` for the request and finished the bookkeeping of the build. A client sees the end of the stream while it is idle, or right after it has written the next `bsp_build_steps` when that request arrives before the maker has finished. With 200 ms between requests on a loaded core, every crash of the reproduction below was the latter; with 2 s between them, the maker had always exited before the next request (the write failed).
- `zig build --listen=-` replaces itself with the maker (`<global cache>/o/<hash>/maker build ... --listen=-`), so the child process of the client is the one that exits.
- Most crashes follow the first request a maker receives; one run of the reproduction crashed after the 14th.
- In zig-analyzer, the log records `<root>: build system exited unexpectedly (EndOfStream, null), restarting` (info), the project shows its "Loading project" progress again and builds once more; nothing is shown to the user and the diagnostics stay. A client that does not restart the maker gets no compiler diagnostics after the crash.

## Cause

Line numbers refer to Zig 0.17.0, with Zig 0.17.1 in parentheses. The parts of `lib/std/Io.zig` and `lib/std/Io/Threaded.zig` cited are the same in both versions.

1. The protocol loop of `lib/compiler/Maker.zig` (lines 840-945 (857-962)) receives message headers through an `Io.Select` (line 852 (869)): `select.concurrent(.message, Server.receiveMessage, .{s})` starts a task that reads one header (lines 860 and 884 (877 and 901)), and `select.await()` waits for it (lines 863 and 914 (880 and 932)).
2. For `bsp_build_steps`, the loop calls `select.cancelDiscard()` to stop the file watching of a previous request (line 876 (893)), reads the request body, starts the task for the next header (line 884 (901)), and builds with `makeSteps` (line 2464 (2501)). `makeSteps` sends `bsp_build_completed` (line 2517 (2554)), then counts the step results and waits for its cleanup task (line 2536 (2573)). The loop then waits for the next event (line 914 (932)).
3. `Io.Select.cancelDiscard` (`Io.zig` lines 1659-1665) returns at once when the group of the select has no running task (its token is null). Otherwise it closes the queue (line 1662) and cancels the group (line 1663). The queue is never reopened, and the documentation of `cancelDiscard` says that calling `await` afterwards is illegal (line 1654): the protocol loop relies on the early return.
4. A select task delivers its result in `Context.start` (`Io.zig` lines 1581-1588): `putOneUncancelable` (line 1585) wakes the waiting `await`. The thread pool removes the task from the group only after `Context.start` returns (`Io/Threaded.zig` line 555 calls it, line 558 decrements `num_running`). In between, the group token is not null although the only task has already delivered its result.
5. When the woken main thread reaches `cancelDiscard` in that window, the queue is closed and the group is canceled. This is likely when the main thread and the receiving thread share a core, or when the receiving thread is preempted. The request is still built as usual, but the next `select.await()` finds the queue closed and empty, and `await` (`Io.zig` lines 1599-1604) maps `error.Closed` to `unreachable` (line 1602), which is the panic above.
6. The protocol loops of the two versions differ only in guards around file watching (`Watch.have_impl`). `makeSteps` and the code of `Io.Select`, `Io.Queue` and the thread pool groups are the same.

## Workaround

`Workspace.run` (`src/server/Workspace.zig`): when the stream of the maker ends after the build graph was read, and the instance is not being stopped, the project is restarted at once as a new instance (`Server.restartWorkspace`; see "Restarts" in [design.md](design.md)).

- The new maker configures the project and builds the files as they are on disk. Until its first build completes, the previous model and compiler diagnostics stay in effect, so a crash publishes no wrong or missing diagnostics.
- A build that was in progress when the maker exited (its request had been written) ends its progress with "Build interrupted", and the first build of the new instance covers it; saves made during the restart are built by the new instance once it has configured. No saved change is lost.
- At most 3 restarts in a row without a completed build (`max_crash_restarts`); the count starts over when an instance completes a build. This race only follows a completed build, so it never reaches the limit. A maker that keeps exiting for another reason does: the user is warned ("zig build keeps exiting unexpectedly, compiler diagnostics are unavailable until build.zig is saved"), the compiler diagnostics are cleared, and the build graph is kept until `build.zig` is saved.
- A maker that exits before sending a build graph failed to configure and is not restarted (see "Restarts" in [design.md](design.md)).
- Cost: each crash costs one configure of the project (the build runner comes from the cache) and one more build of its steps, during which the "Loading project" progress is shown.
- When the maker exited while idle after a completed build and no build has been requested since that build was sent (a save, or a change on disk to build for), the first build of the new instance only repeats it: its result is counted in `Server.repeated_builds` (see `Workspace.repeats`). A restart for any other reason, or a crash during a build that was requested, is not counted there.
- Effect on other tests: the crash can also come after `zig-analyzer/waitIdle` has returned, and the new instance's load, configure and build then add a build, write transactions and publishes of their own. Build counts (`compiles` in `src/server/workspace_e2e_test.zig`) leave out the build that only repeats the completed one, so a test that compares only them needs nothing more ("a build step that rewrites a source file with the same content does not rebuild in a loop", "a change read while a build step is rewriting the file does not build once more", "an open document rewritten on disk is rebuilt, with the client's or the server's watcher"). Write transactions and publishes are not told apart that way: a test that compares them checks after counting whether the project was restarted after a crash (`restartedAfterCrash`), and if so runs again with a new project ("rewriting files on disk without changing their content is not a change").
- Tests (`src/server/workspace_e2e_test.zig`, the maker is ended with `SIGKILL`): "a maker that exits during a build or between builds is restarted, and the new instance builds the saved files", "a maker that keeps exiting before a build completes is restarted three times in a row, then not until build.zig is saved", "restarting a project keeps the previous compiler diagnostics until the new instance has built", and "after the maker exits, the build that repeats the completed one is told apart from requested builds".

## Reproduction

`repro.zig` (from zig-analyzer#1) starts `zig build --listen=-` in an empty project, waits for `bsp_configuration`, reads the default step from the configuration, then sends `bsp_build_steps` (without watching) and waits for `bsp_build_completed`, 200 ms between requests. It reports the request during or before which the maker exited.

```
mkdir project && printf 'pub fn build(b: *@import("std").Build) void {\n    _ = b;\n}\n' > project/build.zig
zig build-exe repro.zig -femit-bin=repro
# keep the same core busy
taskset -c 0 sh -c 'while :; do :; done' & burner=$!
for i in $(seq 1 10); do taskset -c 0 ./repro project 20; done
kill $burner
```

```zig
// repro.zig
//! Repeatedly asks `zig build --listen=-` to build the default step and reports
//! when the maker process dies instead of answering.
//!
//! Usage: zig run repro.zig -- <project-dir> [iterations] [delay-ms]

const std = @import("std");
const Io = std.Io;
const Server = std.zig.Server;
const Client = std.zig.Client;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: {s} <project-dir> [iterations] [delay-ms]\n", .{args[0]});
        return 2;
    }
    const dir = args[1];
    const iterations = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 20;
    // Pause between requests so the maker's message receiver is blocked in a read when the next request arrives.
    const delay_ms = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 200;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "build", "--listen=-" },
        .cwd = .{ .path = dir },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);

    var read_buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &read_buf);
    const r = &reader.interface;
    var write_buf: [256]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &write_buf);
    const w = &writer.interface;

    // Wait for the configuration and look up the default step.
    const default_step: u32 = while (true) {
        const header = try r.takeStruct(Server.Message.Header, .little);
        const body = try r.readAlloc(gpa, header.bytes_len);
        defer gpa.free(body);
        if (header.tag != .bsp_configuration) continue;
        var project = try Io.Dir.cwd().openDir(io, dir, .{});
        defer project.close(io);
        var file = try project.openFile(io, body, .{});
        defer file.close(io);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const conf = try std.Build.Configuration.loadFile(arena.allocator(), io, file);
        break @backingInt(conf.default_step);
    };

    for (0..iterations) |i| {
        if (i != 0) try io.sleep(.fromMilliseconds(delay_ms), .awake);
        sendBuildSteps(w, default_step) catch |err| {
            std.debug.print("maker exited before build request #{d}: {t}\n", .{ i + 1, err });
            return 1;
        };

        while (true) {
            const header = r.takeStruct(Server.Message.Header, .little) catch |err| {
                std.debug.print("maker exited during build request #{d}: {t}\n", .{ i + 1, err });
                return 1;
            };
            r.discardAll(header.bytes_len) catch |err| {
                std.debug.print("maker exited during build request #{d}: {t}\n", .{ i + 1, err });
                return 1;
            };
            if (header.tag == .bsp_build_completed) break;
        }
    }
    std.debug.print("all {d} build requests completed\n", .{iterations});
    return 0;
}

fn sendBuildSteps(w: *Io.Writer, step: u32) Io.Writer.Error!void {
    try w.writeStruct(Client.Message.Header{
        .tag = .bsp_build_steps,
        .bytes_len = @sizeOf(Client.Message.BuildSteps) + 4,
    }, .little);
    try w.writeStruct(Client.Message.BuildSteps{ .step_count = 1, .flags = .{ .watch = false } }, .little);
    try w.writeInt(u32, step, .little);
    try w.flush();
}
```

Results in an arm64 Debian 13 container (glibc 2.41, 8 CPUs, Podman on an Apple M-series Mac) with the official `zig-aarch64-linux` toolchains, 10 runs of 20 requests each:

| Zig | Runs in which the maker crashed |
|---|---|
| 0.17.0 | 3 of 10, each during request 2 |
| 0.17.1 | 6 of 10, five during request 2 and one during request 15 |

Two more series on 0.17.1 with a variant that reads `/proc/<pid>/stat` of the maker before each request crashed in 6 of 12 and 4 of 12 runs; the panicking thread was the main thread, the maker was still running when request 2 was sent 200 ms after the first build, and with 2 s before request 2 it had exited on its own every time.

The server was checked in the same container with a temporary end-to-end test (not part of the repository). `zig` is replaced by a wrapper that counts the `zig build` processes and keeps the stderr of the maker; `main.zig` is saved 60 times, 200 ms apart, each time with another integer out of range, and after each save the compiler diagnostics published for the file must be exactly the new error. The whole `zig build test-stress` ran pinned to core 0 next to a busy loop on the same core, 3 runs per version:

| Zig | Maker panics (`attempt to unwrap error: Closed`) per run | Restarts per run | Saves with the right diagnostics | Warnings shown |
|---|---|---|---|---|
| 0.17.0 | 3, 2, 3 | 3, 2, 3 | 60 of 60 in each run | none |
| 0.17.1 | 2, 3, 2 | 2, 3, 2 | 60 of 60 in each run | none |

With all 8 CPUs, one run per version had no panic.

## Upstream

- [ziglang/zig#37217](https://codeberg.org/ziglang/zig/issues/37217) (Codeberg), "Maker panics on a second build request: `attempt to unwrap error: Closed`": open as of 2026-11-09, with no linked fix.
- On the master branch as of 2026-11-09, the protocol loop of `lib/compiler/Maker.zig` still calls `select.cancelDiscard()` for each `bsp_build_steps` and `select.await()` afterwards, and `Io.Select.cancelDiscard` in `lib/std/Io.zig` is unchanged.
- The restart in `Workspace.run` is not specific to this defect: it also recovers from other maker crashes after a completed build.
