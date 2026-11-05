# Performance: targets, benchmarking, and acceptance results

The targets and the current status of the performance work, the benchmark tooling, and the current acceptance results. Measurement tool: `zig build bench -Doptimize=ReleaseSafe -- <project> <file>...` (see [Benchmark tooling and cross-checks](#benchmark-tooling-and-cross-checks) below). Its output marks each latency in Targets and results as `met` or `MISSED`, except memory.

---

## Targets and results

Benchmark project: the Zig 0.17.0 compiler source (540k lines + standard library), representing the largest workspaces.

| Scenario | Metric | Target | Current | Status |
|---|---|---|---|---|
| Warm | hover / goto p95 | < 50 ms | ≤ 1.3 ms (slowest in the first round: 34 ms) | ✅ |
| | completion p95 | < 100 ms | ≤ 1.2 ms (slowest in the first round: 13 ms) | ✅ |
| | edit → live diagnostics | < 30 ms (excluding debounce) | ordinary files ≤ 9 ms; `Sema.zig` (35k lines) p50 177 ms (including the 50 ms debounce) | ⚠️ very large files |
| | keystroke → hover (continuous typing) | — | `Sema.zig` p50 97 ms; other projects 5-21 ms | — |
| | keystroke → name completion (typing words in a method) | — | `Sema.zig`: auto-import on p50 72-84 ms, p95 160-181 ms; off p50 43-45 ms, p95 67-73 ms (see below) | — |
| | save → compiler diagnostics (`check` step) | < 1 s | small projects about 120 ms; Zig compiler 5.2 s | ⚠️ limited by the compiler |
| | resident memory (long session) | does not grow over the session | Zig compiler source: 2.5-2.8 GB from round 120 on (Linux, see below) | ⚠️ the heap grows |
| Cold start | process start → `initialize` | < 100 ms | 1-9 ms | ✅ |
| | open file → syntax features | < 200 ms | 53 ms (`Sema.zig`) | ✅ |
| | open file → hover / goto / completion | < 3 s | project loading 1.5-4.4 s; hover is available before loading finishes (with incomplete name resolution, which the hover states; see Requests during project loading in `docs/design.md`) | ✅ |
| | workspace symbol index (background) | < 30 s | 1.9 s | ✅ |

Resident memory over a long session on the Zig compiler source:

- Linux, 160 rounds: RSS 2.5-2.8 GB from round 120 on, heap 2.1 GB at round 160, of which 1.8 GB are large allocations. Peak RSS 4.6 GB, with at most 1.55 GB assigned to size classes.
- macOS, 160 rounds: RSS 2.9-3.1 GB from round 120 on, heap 2.1 GB at round 160, of which 2.0 GB are large allocations. Peak RSS 3.9-5.0 GB across runs, with at most 1.5 GB assigned to size classes.
- Windows, 160 rounds: working set 2.9 GB and heap 2.1 GB at round 160. Peak working set 4.7-4.8 GB and peak commit 5.4-5.5 GB, with at most 1.55 GB assigned to size classes.

The heap grows over the session on all three; from round 120 to 160 on Linux it grows from 1.9 to 2.1 GB, mostly in large allocations, while the recorded dependencies grow from 105 to 126 million. The peak comes from the hover that computes the largest instance closure (all instances of `Writer.printValue`): it infers about 900,000 results in one read transaction, which holds at most 512 MB of them. The memory is returned to the system afterwards.

## Real projects

| Project (measured file) | Size | hover p50 | completion p50 | edit → diagnostics p50 | keystroke → hover p50 | Resident memory |
|---|---|---|---|---|---|---|
| Zig 0.17.0 compiler (`src/Sema.zig`) | 540k lines + std | 2.8 ms | 1.5 ms | 177 ms | 97 ms | 718 MB |
| ghostty (`src/terminal/Terminal.zig`) | 370k lines | 1.6 ms | 1.2 ms | 118 ms | 21 ms | 112 MB |
| ZLS (`src/analysis.zig`) | 57k lines | 0.7 ms | 0.5 ms | 90 ms | 16 ms | 218 MB |
| superhtml (`src/html/Tokenizer.zig`) | 43k lines | 0.5 ms | 0.7 ms | 65 ms | 11 ms | 97 MB |
| zigimg (`src/color.zig`) | 38k lines | 0.3 ms | 0.4 ms | 80 ms | 9 ms | 163 MB |
| z2d (`src/compositor.zig`) | 36k lines | 0.4 ms | 0.3 ms | 72 ms | 9 ms | 142 MB |
| libvaxis (`src/Vaxis.zig`) | 25k lines | 0.2 ms | 0.3 ms | 59 ms | 5 ms | 232 MB |
| http.zig (`src/httpz.zig`) | 15k lines | 0.5 ms | 0.4 ms | 64 ms | 9 ms | 105 MB |
| zig-clap (`clap.zig`) | 3k lines | 0.2 ms | 0.3 ms | 62 ms | 5 ms | 84 MB |
| Batch validation of 97 libraries | — | median 0.2 ms, max 1.0 ms | — | — | — | median 93 MB, max 308 MB |

All edit → diagnostics times include the 50 ms debounce.

The completion numbers in this section and in Targets and results are measured without snippets (`BENCH_CONFIG='{"completion":{"snippets":false}}'`); the benchmark client declares `snippetSupport` and uses snippets by default, and their cost is described in `docs/features/completion.md`.

### Semantic tokens

Measured serially on the 97 files in `docs/test-list.md` (ReleaseSafe, project loaded): warm full p95 5.83 ms; delta p95 10.12 ms, max 20.71 ms; warm range p95 0.38 ms.

### Auto-import

Eight names needing an import are typed character by character at the end of the measured file, three times over; each character is an edit plus a completion. Ready is the time from the first completion until auto-import candidates appear. Memory is the peak resident memory.

| Project (measured file) | completion p50 | completion p95 | Ready | Resident memory |
|---|---|---|---|---|
| Cubyz (`src/graphics.zig`) | 3.5 ms | 5.1 ms | 1.6 s | 275 MB |
| flow (`src/tui/mainview.zig`) | 4.9 ms | 7.0 ms | 1.3 s | 411 MB |
| zig-analyzer (`src/sema/infer.zig`) | 4.3 ms | 6.7 ms | 0.7 s | 188 MB |
| Zig compiler (`src/Sema.zig`, 35k lines) | 27 ms | 57 ms | 2.9 s | 680 MB |

On `Sema.zig` with auto-import off, completion p50 is 12.5 ms and p95 30.7 ms, with about 510 MB. Typing whole paths (`memeql`) takes p50 24 ms and p95 44 ms. The first appearance of a candidate whose declaration must be evaluated is the slowest keystroke, at about 0.2 s.

### Typing in a method

`BENCH_TYPE_WORDS` on `zirSliceStart` in `Sema.zig`, where each completion returns about 820 candidates:

| Auto-import | completion p50 | completion p95 | Resident memory |
|---|---|---|---|
| on | 72-84 ms | 160-181 ms | about 470 MB |
| off | 43-45 ms | 67-73 ms | about 310 MB |

Completion after `.` has p50 2.0-2.6 ms. An expected type changes the latency only within measurement noise.

### Naming checks

On `Sema.zig`, edit → diagnostics p50 is 170 ms (169 ms when disabled), codeAction p50 is 3.8 ms, and resolving a local fix takes 68 ms. On ZLS, zigimg, and Cubyz, codeAction p50 is 1.0-1.5 ms, resolving a fix p50 12-19 ms, and the slowest cross-file one 128 ms.

## Known gaps

- **Edit → diagnostics on very large files**: on `Sema.zig`, most of the time goes to reparsing (about 54 ms) and the official AstGen (about 48 ms), about 85 ms with the default configuration; with `diagnostics.inactive_code` enabled, the whole file must also be inferred to compute the inactive code ranges.
- **Keystroke → hover on very large files**: every keystroke requires reparsing and rebuilding ItemTree and FileIndex; on `Sema.zig`, about 100 ms is the lower bound.
- **Save → compiler diagnostics**: the time is spent in the compiler itself; `-fincremental` misses errors in 0.17, so it is not enabled by default.
- **Cold-start find references**: for a declaration referenced from many files, the worst case is 1.9 s (the candidate files exceed the parse cache capacity and are parsed repeatedly); warm p95 is 124 ms.
- **Cold-start goto for `error.Foo`**: when the expected error set does not correspond to a declaration (an inferred error set, `A || B`) or the name has no declaration, file indexes must be built for the whole import closure; on this repository's `src/server/Server.zig`, the first time takes about 0.3 s, after which the file indexes stay resident and the work is not repeated.
- **First full semantic tokens request**: on-demand inference of generic instances and heterogeneous loops still has a cold cost, up to 861 ms across the 97 libraries; this value excludes project loading and must not be substituted with the latency of warm requests or small range requests.
- **First comptime-only check of a large type graph**: proving that a type is not comptime-only computes the types of all the fields reachable from it, through pointers as well, as the compiler does; on `Sema.zig`, the first inference that reaches the `Sema` type walks `Zcu`, `Compilation`, and the parts of `std` they hold, parsing about 80 files, which takes about 0.5 s in that request; the results are cached per type afterwards.

## Analysis per compilation

On a project with one exe and `build.zig`, analyzing shared files per compilation rather than once per file takes open `build.zig` → idle from 49 ms to 84-89 ms and adds about 7% `Infer` / `DeclType` results (the parts of std `build.zig` uses). Hover / goto p50 in `build.zig` is 0.1-0.3 ms, and resident memory stays at about 156-165 MB. A project with one compilation uses the same keys and gets the same results in its own files as with one analysis per file.

## Benchmark tooling and cross-checks

```
zig build bench -Doptimize=ReleaseSafe -- <project root> <file (relative to the project root)>...
```

The benchmark talks to the server as an editor does. Its checks and environment variables are described in the header of `tools/lsp_bench.zig`.

The exit code is 1 when a check below fails its pass criterion or when semantic token deltas do not add up to a full result; `BENCH_SESSION` has no automatic verdict. Missed latency targets do not affect the exit code, because they apply to the benchmark project and Known gaps lists the exceptions.

| Variable | Pass criterion |
|---|---|
| `BENCH_CHECK=<n>` | Mismatches = 0 |
| `BENCH_COMPLETE=<n>` | Recall ≥ 95% |
| `BENCH_REFS=<n>` | Name mismatches, false positives, misses, and rename inconsistencies all 0 |
| `BENCH_SAVE=1` | Identical to `zig build` in file, message, printed location, and notes (not reference traces; not run with a `zig-analyzer.zon`) |

Answers sent right after the first file opens are compared with those once the project is loaded and counted as `same`, `incomplete`, or `different`, without a verdict, since name resolution is incomplete during loading.

`textDocument/formatting` is cross-checked against `zig fmt` of the user's version (identical character for character, apart from the parser differences in `docs/features/formatting.md`).

Batch validation: for each library, dependencies are fetched with `zig build --fetch`, then the benchmark runs with `BENCH_QUICK=1 BENCH_CHECK=40 BENCH_COMPLETE=40 BENCH_REFS=20` on the root-project file with the most member accesses. See `docs/test-list.md`.

## Current acceptance results

| Scope | Result |
|---|---|
| Batch validation of 97 Zig 0.17.0 libraries (zls, zigimg, libvaxis, zine, microzig, Cubyz, flow, raylib, etc.; 2026-10-19) | All have a build graph; crashes / timeouts 0; declaration mismatches 0 (median resolution rate 90.8%, median 100% excluding identifiers without a declaration position); reference and rename errors 0; median completion recall 100%, 95 / 97 ≥ 95%; median hover p50 0.2 ms, max 1.0 ms; median resident memory 93 MB, max 308 MB |
| Corpus cross-check (10305 files, 264.6 MB, 2026-10-16) | All pass; no inconsistency between incremental and full parses under 120k random edits |
| Compiler diagnostics cross-check (2026-10-16) | 15 / 15 identical |
| Formatting cross-check (2026-10-16) | 372 / 372 files identical |

The 2 libraries with recall below 95%: in strand, the members not completed are in comptime reflection code under several layers of generics (such as the result of `descriptor.options(T)`); in morse, `shakedown`, imported by the test code, is added by a test step that does not exist in the default configuration, and is not in the build graph.
