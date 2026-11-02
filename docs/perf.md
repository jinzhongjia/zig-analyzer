# Performance: targets, benchmarking, and acceptance results

The targets and the current status of the performance work, the benchmark tooling, and the current acceptance results. Measurement tool: `zig build bench -Doptimize=ReleaseSafe -- <project> <file>...` (see [Benchmark tooling and cross-checks](#benchmark-tooling-and-cross-checks) below).

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
| | resident memory (long session) | does not grow over the session | Zig compiler source, 240 rounds on Linux: 1.1-1.4 GB from round 120 on, heap about 520 MB. The allocator's memory stays flat (0.43 GB of pages for 0.18 GB of live small blocks, and 0.36 GB of large allocations); the rest, mostly worker stacks (0.57 GB at round 240), grows in steps as deeper recursions touch more of them. The rounds that compute the largest type graphs peak at 10.1 GB, which is returned to the system afterwards. macOS, 240 rounds: RSS 0.89-1.24 GB and physical footprint 1.12-1.36 GB from round 120 on (peak footprint 11.6 GB). Windows, 40 rounds: working set 0.87 GB with 0.98 GB committed at round 40 (peak working set 10.1 GB) | ⚠️ worker stacks |
| Cold start | process start → `initialize` | < 100 ms | 1-9 ms | ✅ |
| | open file → syntax features | < 200 ms | 53 ms (`Sema.zig`) | ✅ |
| | open file → hover / goto / completion | < 3 s | project loading 1.5-4.4 s; hover is available before loading finishes (with incomplete name resolution) | ✅ |
| | workspace symbol index (background) | < 30 s | 1.9 s | ✅ |

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

Semantic tokens are additionally measured serially on the 97 files specified in `docs/test-list.md` (ReleaseSafe, project loading finished, call-site inference enabled):
warm full p95 5.83 ms; delta after inserting/undoing a comment p95 10.12 ms, max 20.71 ms; warm range p95 0.38 ms.
The first 10-line range on Cubyz, strand, flow, and element-0 takes 0.31-2.89 ms; an empty range runs no Infer / seed queries.

Measured with auto-import enabled (ReleaseSafe): in a function at the end of the measured file, eight names that need an import (`ArrayLi`, `Allocat`, `asser`, `Resolv`, `Hash`, `mem`, `Thread`, `parseIn`) are typed character by character, three times over; each character is an edit followed by a completion request, and the timing includes both. Every completion offered auto-import candidates. Ready is the time from the first completion, which triggers building the index, until auto-import candidates appear, while typing continues at 150 ms intervals; ordinary completion is provided as usual in the meantime (the slowest such completion took 24-31 ms). Memory is the peak resident memory of the process.

| Project (measured file) | completion p50 | completion p95 | Ready | Resident memory |
|---|---|---|---|---|
| Cubyz (`src/graphics.zig`) | 3.5 ms | 5.1 ms | 1.6 s | 275 MB |
| flow (`src/tui/mainview.zig`) | 4.9 ms | 7.0 ms | 1.3 s | 411 MB |
| zig-analyzer (`src/sema/infer.zig`) | 4.3 ms | 6.7 ms | 0.7 s | 188 MB |
| Zig compiler (`src/Sema.zig`, 35k lines) | 27 ms | 57 ms | 2.9 s | 680 MB |

With the same input on `Sema.zig` but auto-import disabled, completion p50 is 12.5 ms and p95 30.7 ms, with about 510 MB of resident memory; the difference comes mainly from `FileIndex`, `ItemSummaries` (which `Resolver` depends on when resolving imports of named modules and finding container locations), and `ImportSites`, recomputed for the current file after each keystroke. Completing right after adding or removing an `@import` line at the top of the file takes p50 6-7 ms, slowest 17 ms on Cubyz, flow, and zig-analyzer, and p50 37 ms, slowest 70 ms on `Sema.zig`, mostly for the reparse after an edit at the top of the file; recomputing `TestOnlyFiles` takes less than 1 ms of that.

When whole paths are typed (`memeql`, `fmtalloc`, `heaparena`, `ArrayHashMap`, `debugassert`, likewise character by character, three times over), completion on `Sema.zig` takes p50 24 ms and p95 44 ms: each completion fuzzy-matches and scores all exports within two segments below the visible namespaces and the module roots.

The kind of a completion item may require the declaration's type the first time a candidate appears: among auto-import candidates, the keystroke at which a declaration that must be evaluated (such as `std.Target.x86.all_features = blk: {...}`) first appears is the slowest, at about 0.2 s, and later keystrokes hit the cache; the first name completion after `Sema.zig` is opened takes about 70 ms (inferring the declared types of the members in scope), and about 2 ms afterwards; the first round of completion after `.` takes at most 19 ms.

When typing in a method (`BENCH_TYPE_WORDS`: `zirSliceStart` in `Sema.zig` has 11 local values such as `sema: *Sema` and `block: *Block`; `zcu`, `gpa`, `typeOf`, `resolveInst`, `instructions`, `fail`, `arena`, and `ptr_src` are typed character by character in a new statement after line 9803, waiting for background work to finish before each keystroke, and the timing covers only the edit and the completion), each completion returns about 820 candidates, of which member paths of local values average 86 (with auto-import on, at most 128 together with the auto-import candidates) or 111 (with it off). With auto-import on, completion p50 is 72-84 ms and p95 160-181 ms, with about 470 MB of resident memory; with it off, p50 is 43-45 ms and p95 67-73 ms, with about 310 MB. Of this, member paths take about 1.5-3 ms per keystroke, and at most about 10 ms when the signature of a matched method is first computed. When typing where there is an expected type (`const probe: Air.Inst.Ref = ▮;`), types are computed for all returned candidates: under 1.2 ms per keystroke with auto-import off; with it on, p50 1.8 ms and at most 31 ms (the declaration's type is computed the first time a standard library candidate appears, and hits the cache afterwards); the completion latency differs from typing where there is no expected type (`_ = ▮;`) only within the measurement noise. Completion after `.` has p50 2.0-2.6 ms.

Naming checks (enabled, ReleaseSafe): on the Zig compiler's `src/Sema.zig`, edit → diagnostics p50 is 170 ms (169 ms when disabled); each edit recomputes only the edited
member and reads no other files; codeAction p50 is 3.8 ms, and resolving the fix for a local name (including AstGen of the whole file after the rename) takes 68 ms. On ZLS, zigimg, and Cubyz,
codeAction p50 is 1.0-1.5 ms, resolving a fix p50 12-19 ms, and the slowest cross-file one 128 ms (a field with 63 references).

## Known gaps

- **Edit → diagnostics on very large files**: on `Sema.zig`, most of the time goes to reparsing (about 54 ms) and the official AstGen (about 48 ms), about 85 ms with the default configuration; with `diagnostics.inactive_code` enabled, the whole file must also be inferred to compute the inactive code ranges.
- **Keystroke → hover on very large files**: every keystroke requires reparsing and rebuilding ItemTree and FileIndex; on `Sema.zig`, about 100 ms is the lower bound.
- **Save → compiler diagnostics**: the time is spent in the compiler itself; `-fincremental` misses errors in 0.17, so it is not enabled by default.
- **Cold-start find references**: for a declaration referenced from many files, the worst case is 1.9 s (the candidate files exceed the parse cache capacity and are parsed repeatedly); warm p95 is 124 ms.
- **Cold-start goto for `error.Foo`**: when the expected error set does not correspond to a declaration (an inferred error set, `A || B`) or the name has no declaration, file indexes must be built for the whole import closure; on this repository's `src/server/Server.zig`, the first time takes about 0.3 s, after which the file indexes stay resident and the work is not repeated.
- **First full semantic tokens request**: on-demand inference of generic instances and heterogeneous loops still has a cold cost, up to 861 ms across the 97 libraries; this value excludes project loading and must not be substituted with the latency of warm requests or small range requests.
- **First comptime-only check of a large type graph**: proving that a type is not comptime-only computes the types of all the fields reachable from it, through pointers as well, as the compiler does; on `Sema.zig`, the first inference that reaches the `Sema` type walks `Zcu`, `Compilation`, and the parts of `std` they hold, parsing about 80 files, which takes about 0.5 s in that request; the results are cached per type afterwards.

## Analysis per compilation

Shared files are analyzed once per compilation that reaches them (see `docs/design.md`, Name layer and HIR). Measured on this repository (one exe compilation, plus `build.zig` in the compilation of the build scripts) with `BENCH_QUICK=1 zig build bench -Doptimize=ReleaseSafe -- <repository> src/sema/infer.zig src/server/Server.zig build.zig`, two runs each, against the same build with one analysis per file:

| Metric | One analysis per file | Per compilation |
|---|---|---|
| hover / goto / completion p50 in `infer.zig`, `Server.zig` | 0.6-1.0 ms | 0.5-1.0 ms |
| open `build.zig` → idle (its standard library is analyzed for the host) | 49 ms | 84-89 ms |
| hover / goto p50 in `build.zig` | 0.1 ms | 0.1-0.3 ms |
| `Infer` / `DeclType` results over the run | 12013 / 10504 | 12769 / 11241 (+6%, +7%: the parts of std `build.zig` uses) |
| `DeclType` + `CallEval` self time over the run | 118 ms | 158-166 ms |
| resident memory at the end | 156-163 MB | 156-165 MB |

A project with one compilation gives the same keys and results in its own files as before; selecting the compilation costs one cached lookup per computation and per file crossed.

## Benchmark tooling and cross-checks

```
zig build bench -Doptimize=ReleaseSafe -- <project root> <file (relative to the project root)>...
```

The benchmark starts the server as a child process and talks to it the way an editor does (like common editors, it declares `snippetSupport` for completion), measuring cold start, hover / goto / completion latency, edit → diagnostics, continuous typing, and memory. Environment variables enable the individual checks (see the header of `tools/lsp_bench.zig` for details):

| Variable | Check | Pass criterion |
|---|---|---|
| `BENCH_CHECK=<n>` | Requests declaration for identifiers; the name at the target must equal the name at the request position; unresolved identifiers are counted by kind (primitive types, `len` / `ptr`, error names, `.` literals, member access, labels, names) | Mismatches = 0 |
| `BENCH_COMPLETE=<n>` | Completes each `a.b` in the source after the `.`; the list must contain `b` | Recall ≥ 95% |
| `BENCH_CONCURRENT=<n>` | Throughput: opens the n largest files of the project at once and requests their full semantic tokens without waiting for the answers, as an editor restoring n tabs does; reports the time until the last answer, the latency of each request, and the memory afterwards | Timing covers the opens and all the answers |
| `BENCH_REFS=<n>` | Find references and rename; references in a generic function body that point to a same-named declaration under another call site's instance are counted separately | Name mismatches, false positives, misses, and rename inconsistencies all 0 |
| `BENCH_SAVE=1` | Save → compiler diagnostics, compared one by one with `zig build` | Identical |
| `BENCH_SESSION=<rounds>` | Memory over a long session (`imp MB` is the value for the auto-import index; `small`, `resid`, `slots`, `kept`, `ret`, `large` and `dec k` are the allocator's figures from `zig-analyzer/status`, `occupancy %` the share of its pages by the eighth of their blocks in use, `thp` the memory in transparent huge pages on Linux, and `commit` the private commit on Windows), and the latencies of the session's requests | Stable, within budget |
| `BENCH_TYPE_COMPLETE=<n>` | Completion while typing: insert a character in a name expression → complete → undo, also reporting the number of auto-import candidates and the changes in index queries (auto-import is on by default; disable it with `BENCH_CONFIG='{"completion":{"auto_import":false}}'` to compare the cost) | Timing includes the edit and the completion |
| `BENCH_TYPE_WORDS=<line>:<word>,<word>...` | Types each word character by character in a new statement after line `<line>`, requesting completion after each character; waits for background work to finish before each keystroke, so the timing covers only that edit and completion; also reports the number of candidates and how many of them are member paths of local values | Timing includes the edit and the completion |
| `BENCH_TYPE_STMT=<statement>` | The statement `BENCH_TYPE_WORDS` inserts, with `\|` marking where to type (default `_ = \|;`); e.g. `const probe: Air.Inst.Ref = \|;` types where there is an expected type | — |
| `BENCH_QUICK=1` | Skips the edit-related phases; used for batch validation | — |

In addition, `textDocument/formatting` is cross-checked against `zig fmt` (identical character for character).

Batch validation: for each library, the dependencies are first fetched with `zig build --fetch`; then the benchmark runs with `BENCH_QUICK=1 BENCH_CHECK=40 BENCH_COMPLETE=40 BENCH_REFS=20` on the one file in the root project (excluding subdirectories with their own `build.zig`, tests, and examples) that has the most member accesses. See `docs/test-list.md` for the projects, commits, and measured files.

## Current acceptance results

| Scope | Result |
|---|---|
| Batch validation of 97 Zig 0.17.0 libraries (zls, zigimg, libvaxis, zine, microzig, Cubyz, flow, raylib, etc.; 2026-10-19) | All have a build graph; crashes / timeouts 0; declaration mismatches 0 (median resolution rate 90.8%, median 100% excluding identifiers without a declaration position); reference and rename errors 0; median completion recall 100%, 95 / 97 ≥ 95%; median hover p50 0.2 ms, max 1.0 ms; median resident memory 93 MB, max 308 MB |
| Corpus cross-check (10305 files, 264.6 MB, 2026-10-16) | All pass; no inconsistency between incremental and full parses under 120k random edits |
| Compiler diagnostics cross-check (2026-10-16) | 15 / 15 identical |
| Formatting cross-check (2026-10-16) | 372 / 372 files identical |

The 2 libraries with recall below 95%: in strand, the members not completed are in comptime reflection code under several layers of generics (such as the result of `descriptor.options(T)`); in morse, `shakedown`, imported by the test code, is added by a test step that does not exist in the default configuration, and is not in the build graph.
