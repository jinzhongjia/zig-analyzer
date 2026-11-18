# zig-analyzer: Improvements Over ZLS

English | [简体中文](improvements-over-zls.zh-CN.md)

**Technical note · v1.0 · 2026-11-18**

**Subjects:** zig-analyzer `0.2.1+20.g7108016` and ZLS `0.17.0`  
**Scope:** language-server behavior — correctness, semantics, refactoring safety, build integration, protocol surface, and measured performance.  
**Out of scope:** editor and installation ecosystem. Both projects support mainstream editors and installation paths; this note does not compare that dimension.

---

## 1. Executive summary

This note describes what zig-analyzer does better than ZLS 0.17.0, with measured results and deterministic case studies. It is not a claim that zig-analyzer wins on every axis; ZLS remains a mature, lightweight server and is the better choice for some workflows. The trade-offs are listed in sections 5–6.

The main improvements are:

1. **Diagnostics come from the Zig compiler, not from a heuristic analysis layer.** zig-analyzer defines and tests diagnostic consistency with `zig build`: same file, positions, severity, message, notes, and reference traces. ZLS can obtain compiler diagnostics only through build-on-save, and only when the project has a `check` step or build-on-save is explicitly enabled.
2. **Comptime and generic code are analyzed, not approximated.** zig-analyzer evaluates comptime expressions and infers generic function bodies from call-site instances. In a deterministic fixture, ZLS returned no hover/goto and missed a field completion for a member of an `anytype` value; zig-analyzer resolved the concrete `u64` field and its declaration.
3. **Refactoring is safer.** In a cross-file method-call test, ZLS returned one reference, renamed only the declaration, and left the call site broken; `zig build check` failed. zig-analyzer found both references, edited both files, and the project still compiled.
4. **Completion is semantic and can add imports.** zig-analyzer offers auto-import candidates with the required edit and completes member paths; ZLS has no symbol auto-import.
5. **ZON is a first-class file type.** zig-analyzer provides ZON outline, typed completion/goto/inlay hints, `build.zig.zon` schema support, and dependency-hash actions. ZLS treats `.zon` mostly as syntax/formatting; its document-symbol result for a valid `build.zig.zon` was empty.
6. **The build model is deeper.** zig-analyzer uses compile sets, per-compilation analysis, generated paths, and sub-projects. ZLS's build configuration merges modules with the same root file, a limitation documented in its own source.
7. **Warm-path latency is often lower.** On the ZLS source tree, zig-analyzer's goto p50 was 0.23 ms vs 0.52 ms, completion p50 0.44 ms vs 0.79 ms, and initialization 0.67 ms vs 19.1 ms. On the zig-analyzer source tree, goto p95 and completion p50/p95 also favored zig-analyzer.

The main costs are memory, binary size, default diagnostic latency (50 ms debounce), hover tail latency in generic code, and project age. These are quantified in sections 5–6.

---

## 2. Measurement setup

| Item | Value |
|---|---|
| OS / kernel | Arch Linux, 7.3.4-zen2-2-zen |
| CPU / RAM | Intel Core Ultra 7 255H, 16 logical CPUs / 62 GiB |
| Zig | 0.17.1 |
| Builds | Both `-Doptimize=ReleaseSafe` |
| zig-analyzer | `0.2.1+20.g7108016`, commit `7108016` |
| ZLS | `0.17.0`, tag commit `542462c` |
| Project A | ZLS 0.17.0 source, 37,643 Zig LOC; measured `src/analysis.zig` (7,006 lines) |
| Project B | zig-analyzer source, 138,842 Zig LOC; measured `src/sema/infer.zig` (5,235 lines) |
| Client | Purpose-built LSP 3.17 client, UTF-8 positions, sequential requests, 3 runs per server for projects A and B |

Latency is end-to-end: JSON serialization, pipe transport, server processing, and client parsing. Warm measurements follow a 6 s settle and a warm-up pass. RSS is read from `/proc/<pid>/status` after the workload, not peak RSS. The benchmark harness is a purpose-built LSP client; it is not part of this repository. Section 8 lists the limits of the study.

**Important:** every round ran zig-analyzer first and ZLS second. The order was not randomized; if that creates a bias, it favors ZLS (warmer file caches).

---

## 3. Improvements in detail

### 3.1 Diagnostics: compiler-consistent by construction

zig-analyzer's published compiler diagnostics are produced from the official `ErrorBundle` returned by the Zig build system protocol. Its consistency definition is explicit: for the same disk contents, Zig version, build step, and arguments, the diagnostics equal `zig build <step>` entry by entry, including positions, severity, message text, notes, and reference traces. Live diagnostics use the official parser and AstGen in-process (falling back to `zig ast-check` when the user's Zig differs from the built-in AST version).

ZLS's live diagnostics are AstGen diagnostics plus its own style/autofix diagnostics. Compiler/Sema diagnostics require build-on-save: when `build.zig` declares a `check` step, ZLS auto-enables build-on-save; otherwise the user must enable it explicitly, and without a `check` step it can only run the default step or not build at all.

Measured behavior:

| Scenario | zig-analyzer | ZLS |
|---|---|---|
| Project with `check` step, semantic type error on open | Error after **684 ms**, source `zig` | Error after **383 ms**, source `zls` |
| Project without `check` step, same error | Error after **1.31 s**, source `zig` | **No error within 10 s** |
| `enable_build_on_save=false` | Still reports compiler error | Only AstGen; no Sema error |

**Why it matters:** a type error, a missing field, or a failed link is exactly what a user needs after saving. Requiring a `check` step or an opt-in build setting makes that correctness conditional.

### 3.2 Comptime and generic instances

zig-analyzer has a comptime interpreter and an instance model: a generic body is inferred under the instances produced by its call sites, and comptime branches are evaluated rather than approximated. ZLS has a type analyser and an intern pool, but its README states that comptime and semantic analysis are work in progress.

Deterministic fixture:

```zig
fn show(x: anytype) void {
    std.debug.print("{d}\n", .{x.value});
}

fn Box(comptime T: type) type {
    return struct {
        value: T,
        pub fn get(self: @This()) T { return self.value; }
    };
}

const Chosen = if (builtin.os.tag == .linux) u32 else u64;

pub fn main() !void {
    const b = Box(u64){ .value = 7 };
    show(b);
    ...
}
```

| Query | zig-analyzer | ZLS 0.17.0 |
|---|---|---|
| Hover on `x.value` inside `show` | `value: u64`, with the call site | `null` |
| Completion after `x.` | `get`, `value` | `get` only |
| Goto on `value` | Field declaration in `Box` | `null` |
| Hover on `self.value` in `Box.get` | `value: u64` | `value: T` |
| Hover on `Chosen` | `type = u32` | Shows both `u32` and `u64` |

ZLS is not devoid of call-site inference: for `identity(x: anytype)` called with `u32`, it shows `x: anytype` plus `(type = u32)`. The gap is specifically in member access on an `anytype` value, fields of a generic container, and comptime branch selection.

**Why it matters:** generic and comptime-heavy code is common in Zig's standard library, allocators, serialization, and compile-time configuration. A server that returns `null` there sends the user back to reading source.

### 3.3 Refactoring safety

zig-analyzer searches references across the module graph and user files, refuses rename when a reference cannot be confirmed or the new name is ambiguous, and validates the renamed file with AstGen. ZLS's reference search is narrower.

Concrete test: `widget.zig` declares `pub fn resize(...)`; `main.zig` calls `w.resize(4)`. Requesting references/rename on the declaration:

| Metric | zig-analyzer | ZLS |
|---|---|---|
| References (including declaration) | **2** | **1** |
| Files edited by rename | **2** | **1** |
| `zig build check` after rename | **Passes** | **Fails** |

ZLS's failure:

```text
src/main.zig:38:6: error: no field or member function named 'resize' in 'widget.Widget'
    w.resize(4);
    ~^~~~~~~
```

The result was the same when `main.zig` was already open and the server had 5 s to settle. To isolate the rename, the test copy changes an unrelated `var never_mutated` to `const`; both servers are treated identically. ZLS did not find the cross-file method call and still returned a rename edit instead of refusing. That is a correctness issue, not a style preference.

**Why it matters:** a rename that silently leaves a call site behind turns a refactor into a build break. A server that refuses when uncertain is more useful than one that always returns an edit.

### 3.4 Completion and auto-import

zig-analyzer's completion is based on inference and name resolution. It offers:

- names in scope, with fuzzy ranking and expected-type boosting;
- members of local values, including member paths such as `sema.gpa`;
- auto-import candidates for declarations that are not imported yet, with the import edit;
- snippets for calls, statements, and declarations;
- `completionItem/resolve` for signatures and documentation on selection.

ZLS has semantic completion and snippets, but no symbol auto-import. Its completion items do not carry `additionalTextEdits`, and in our runtime test an unimported `add` was never offered; zig-analyzer offered it with an import edit once its background index was ready.

Measured completion recall on member accesses:

| Project | zig-analyzer | ZLS |
|---|---|---|
| A (ZLS source) | 90/90 = **100%** | 90/90 = **100%** |
| B (zig-analyzer source) | 70/70 = **100%** | 64/70 = **91.4%** |

ZLS's misses on B were member accesses that needed cross-call/container type inference. The sample is small and the confidence intervals overlap, but the deterministic fixture above shows the same direction.

**Why it matters:** auto-import is a daily editing action in a language where every file starts with `@import`. Without it, the user must remember the module path and write the import by hand.

### 3.5 ZON

zig-analyzer treats `.zon` as a first-class file type:

- parsing, formatting, and diagnostics for any `.zon` file;
- outline of the root expression;
- typed completion, goto, and inlay hints for `.zon` files imported with a result type;
- `build.zig.zon` completion with the manifest schema;
- completion and option descriptions in `zig-analyzer.zon`;
- a code action that runs `zig fetch` for a dependency URL and writes its hash.

ZLS formats `.zon` and has some syntax support, but several semantic features explicitly return `null` for `.zon` (signature help, inlay hints, references), and a valid `build.zig.zon` produced **0** document symbols in our test; zig-analyzer produced **5** (`name`, `version`, `fingerprint`, `minimum_zig_version`, `paths`).

Both formatters produced byte-identical output to `zig fmt` on an unformatted `.zig` and `.zon` file in our test. Formatting is not the differentiator; semantic ZON support is.

**Why it matters:** `build.zig.zon` is the project manifest. Editing it without schema completion, outline, or hash assistance is slower and error-prone.

### 3.6 Build system integration

zig-analyzer is a client of `zig build --listen=-` for the project model: build graph, compile steps, modules, generated files, and compiler diagnostics. It maintains compile sets, analyzes shared files per compilation, resolves generated paths against the actual cache, and loads sub-projects (examples/benchmarks with their own `build.zig` and a `.path` dependency on the root).

ZLS also integrates with the build system, but its build configuration merges modules with the same root source file; the source comments call this a limitation. It has no equivalent sub-project loading mechanism in the version reviewed.

**Why it matters:** in a project with a host tool and a cross-compiled target, or a library with examples, the same file can be compiled with different `builtin`/module settings. A model that merges those contexts can produce incomplete or wrong navigation.

### 3.7 Protocol surface

zig-analyzer exposes several LSP details that ZLS does not:

| Capability | zig-analyzer | ZLS 0.17.0 |
|---|---|---|
| `completionItem/resolve` | Yes | No |
| Semantic tokens delta | Yes | No (full/range only) |
| Code action resolve | Yes | No |
| `executeCommand` for dependency hash | Yes (when the client supports `workspace/applyEdit`) | No |
| `zig-analyzer/packages` inspection | Yes | No |
| `willSaveWaitUntil` | No | Yes, but only as a `force_autofix` fallback |

On `willSaveWaitUntil`: ZLS's implementation is not a general save pipeline. It is used only when `force_autofix` is enabled (default: false), only for manual saves, and only for `source.fixAll`. It exists for clients that do not support code actions on save. zig-analyzer instead exposes `source.fixAll` and `source.organizeImports` for the editor to invoke on save. For a modern client, that is the more predictable path; it does not block the save request.

### 3.8 Configuration and team settings

zig-analyzer has about 44 user settings in a nested JSON/ZON structure, including auto-import limits, naming rules, unused declarations, inactive code, cache sizes, sub-projects, logging, and diagnostics debounce. Project-related settings can be shared in `zig-analyzer.zon` at the project root, with comments, type validation, completion, and hover documentation.

ZLS has 22 flat settings and a `zls.json` loaded from the global/local configuration directory. It is simpler, but less expressive for a team that wants to commit project settings.

**Why it matters:** a large project often needs per-repository settings (build args, diagnostics steps, naming policy). A project-root file that is validated and documented is easier to maintain than editor-specific JSON.

### 3.9 Measured performance advantages

Warm-path medians, 3 runs per cell:

| Project | Metric | zig-analyzer | ZLS | Comment |
|---|---|---|---|---|
| A | `initialize` | **0.67 ms** | 19.1 ms | ZLS resolves Zig/build configuration before replying |
| A | hover p50 / p95 | **0.37 / 1.91 ms** | 0.58 / **1.31 ms** | ZLS has the better tail |
| A | completion p50 / p95 | **0.44 / 3.85 ms** | 0.79 / 4.16 ms | |
| A | goto p50 / p95 | **0.23 / 0.46 ms** | 0.52 / 1.04 ms | |
| A | semantic tokens full | **49.5 ms** | 70.2 ms | token sets differ; magnitude only |
| A | edit → diagnostics p50 | 56.2 ms | **6.0 ms** | 50 ms debounce; 7 ms when disabled |
| A | RSS | 127.1 MiB | **60.9 MiB** | |
| B | `initialize` | **0.83 ms** | 48.1 ms | |
| B | hover p50 / p95 | 0.52 / 3.42 ms | 0.52 / **1.18 ms** | |
| B | completion p50 / p95 | **0.91 / 2.71 ms** | 1.88 / 6.89 ms | |
| B | goto p50 / p95 | **0.37 / 0.54 ms** | 0.40 / 0.92 ms | |
| B | edit → diagnostics p50 | 58.2 ms | **5.4 ms** | |
| B | RSS | 127.8 MiB | **66.5 MiB** | |

Fixed 250-request CPU probe on project A:

| Metric | zig-analyzer | ZLS |
|---|---|---|
| Wall time | **244 ms** | 341 ms |
| CPU time | **190 ms** | 250 ms |
| CPU per request | **0.76 ms** | 1.00 ms |

The performance story is not “zig-analyzer is always faster”. It is:

- much faster initialization handshake;
- usually lower goto/completion p50 and p95;
- lower CPU per request in the fixed workload;
- but higher memory and binary size;
- worse hover tail on the larger project;
- slower default diagnostics because of the 50 ms debounce (configurable).

### 3.10 Observability and release safety

zig-analyzer logs through `std.log` with a runtime level filter and an optional log file. `log.slow_request_ms` prints a query breakdown for slow requests (for example `ParseFile`, `DeclType`, `Infer` self times), which makes performance work and bug reports concrete. Release builds are ReleaseSafe: a bug stops the server with a stack trace instead of silently returning wrong results, and release artifacts include debug information. Releases are signed with minisign and have build provenance attestations.

ZLS has standard stderr logging and mature operational experience, but not the same query-level slow-request breakdown or the explicit “crash instead of wrong answer” policy.

**Why it matters:** a language server is infrastructure. When it misbehaves, the log is the product. Query-level timing and a fail-fast policy shorten diagnosis.

---

## 4. Evidence table

| Claim | Evidence | Caveat |
|---|---|---|
| Compiler-consistent diagnostics | Defined in `docs/diagnostics.md`; 15/15 cross-check (project-reported); measured semantic error with and without `check` step | The 15/15 suite was not independently reproduced here |
| Comptime/generic resolution | Fixture: `x.value` hover/goto/completion, `Chosen` branch | Small fixture, not a corpus study |
| Safer rename | Fixture: ZLS 1 reference, build fails; zig-analyzer 2 references, build passes | One cross-file method-call pattern; not all rename cases |
| Auto-import | Source: ZLS has no `additionalTextEdits`; runtime: unimported `add` not offered | Indexing is asynchronous; first completion can be incomplete |
| ZON outline | Valid `build.zig.zon`: 5 symbols vs 0 | One manifest file |
| Build model | Source: compile sets, sub-projects; ZLS module-merge comment | Not benchmarked on a multi-target project |
| Warm latency | 3 runs, 30–180 samples per metric | Single machine; order not randomized |
| Memory/binary | `/proc` RSS; `strip --all`; `size` | Not peak RSS; one workload |
| Long-session stability | 40 edit rounds: zig-analyzer 86.3 MiB stable; ZLS 27.4 → 45.4 MiB | 40 rounds is short; ZLS growth may be cache warm-up |
| CPU efficiency | 250 requests: 0.76 vs 1.00 ms/request | Single run |

---

## 5. Where ZLS remains stronger

A credible improvements document must list the other side.

1. **Memory:** ZLS used 60.9 MiB vs 127.1 MiB on project A and 66.5 MiB vs 127.8 MiB on project B — about half. On a 40-line fixture it used 14.4 MiB vs 49.0 MiB.
2. **Binary size:** 20.1 MB vs 48.6 MB full; 3.5 MB vs 7.7 MB stripped.
3. **Default diagnostic latency:** AstGen diagnostics appear in 5–6 ms vs zig-analyzer's 56–58 ms with the default 50 ms debounce. Setting `diagnostics.debounce_ms=0` brings zig-analyzer to about 7 ms, but that is not the default.
4. **Hover tail latency on the larger project:** ZLS p95 1.18 ms vs 3.42 ms on project B. zig-analyzer's generic instance work has a long tail.
5. **Hover p50 on project B:** a tie at 0.52 ms, not a zig-analyzer win.
6. **Semantic tokens on project B:** ZLS 32.0 ms vs 38.6 ms.
7. **Simplicity and maturity:** 22 flat settings vs about 44 nested settings; a long deployment history; a smaller surface to learn and operate. ZLS is a reasonable default for ordinary code and resource-constrained machines.
8. **Zig master:** ZLS master targets Zig 0.18.0-dev; zig-analyzer 0.2.1 targets Zig 0.17.0/0.17.1. If you track Zig master, ZLS is the practical option.

None of these erase the semantic advantages above; they define the cost and the cases where ZLS is the better tool.

---

## 6. Migration notes from ZLS

1. **Configuration shape:** ZLS uses a flat 22-key JSON. zig-analyzer uses nested JSON/ZON; put project settings in `zig-analyzer.zon`.
2. **On-save actions:** use `source.fixAll` and `source.organizeImports` from the editor's code-action-on-save hook. Do not expect `willSaveWaitUntil` to replace it; that ZLS capability is a `force_autofix` fallback, not a general save pipeline.
3. **Diagnostics:** zig-analyzer compiles on load/save through the build system, so expect initial project loading and a higher memory footprint. In exchange, Sema errors do not depend on a `check` step.
4. **Rename:** zig-analyzer is stricter. If it refuses a rename, do not bypass it blindly; the refusal usually means a reference is ambiguous or a string literal mentions the name.
5. **Performance tuning:** if the 50 ms diagnostic debounce feels slow, set `diagnostics.debounce_ms=0`. If memory is tight, review `sema.max_intern_pool_mb` and `cache` limits.
6. **Editor setup:** both servers support mainstream editors; use the existing editor integrations and on-save hooks rather than adding a server-side pre-save workaround.

---

## 7. Measurement notes

- Both servers were built from source with Zig 0.17.1 in `ReleaseSafe`.
- Latency is end-to-end LSP latency; warm state follows a 6 s settle and a warm-up pass.
- Projects A and B each ran three times per server. Section 3.9 reports medians; the appendix lists every run.
- RSS is the post-workload `VmRSS`, not peak RSS.
- Per run: 60–100 hover samples, 40–60 goto samples, 20–30 completion samples, and 2–3 edit-to-diagnostics rounds.
- The benchmark harness is a purpose-built LSP client and is not part of this repository; section 8 lists the limits of the study.

## 8. Limitations

- Single machine, Linux x86-64, Zig 0.17.1; no macOS/Windows.
- Two real projects plus one small fixture; both projects are language-server/compiler infrastructure code with heavy generics, which may overstate zig-analyzer's advantage.
- Small samples (30–180 per metric); Wilson intervals are wide for proportions.
- Each round ran zig-analyzer first, ZLS second; the order was not randomized, which may favor ZLS.
- ZLS used the 0.17.0 tag, not the tip of the 0.17.x branch; later fixes are not included.
- Performance tests disabled ZLS build-on-save, while zig-analyzer compiler diagnostics were on; the initialization workload differs.
- `willSaveWaitUntil` was assessed from source and a small runtime probe, not a broad client matrix.
- Project-reported validation (97 libraries, 10,305-file corpus, 15/15 diagnostics, 372/372 formatting) is labeled as such and was not independently reproduced.

## Appendix: per-run measurements

### Project A: ZLS source, `src/analysis.zig`

| Run | Server | init ms | hover p50/p95 | completion p50/p95 | goto p50/p95 | edit p50 | semtok ms | RSS KiB |
|---|---|---|---|---|---|---|---|---|
| 1 | za | 0.674 | 0.368/1.911 | 0.467/4.021 | 0.233/0.408 | 56.419 | 49.5 | 130,496 |
| 2 | za | 0.768 | 0.393/1.946 | 0.440/3.854 | 0.266/0.462 | 55.806 | 45.0 | 130,168 |
| 3 | za | 0.648 | 0.328/1.692 | 0.378/3.692 | 0.224/0.816 | 56.188 | 50.0 | 123,344 |
| 1 | zls | 19.075 | 0.584/1.320 | 0.987/5.111 | 0.523/1.218 | 8.587 | 70.2 | 62,744 |
| 2 | zls | 19.451 | 0.633/1.063 | 0.729/4.155 | 0.595/1.037 | 6.023 | 86.1 | 61,004 |
| 3 | zls | 13.836 | 0.554/1.314 | 0.789/3.753 | 0.442/0.724 | 5.379 | 39.4 | 62,380 |

### Project B: zig-analyzer source, `src/sema/infer.zig`

| Run | Server | init ms | hover p50/p95 | completion p50/p95 | goto p50/p95 | edit p50 | semtok ms | RSS KiB |
|---|---|---|---|---|---|---|---|---|
| 1 | za | 0.83 | 0.76/2.52 | 0.91/2.41 | 0.66/0.88 | 58.2 | 31.8 | 132,100 |
| 2 | za | 0.95 | 0.23/3.42 | 0.66/2.71 | 0.06/0.40 | 56.9 | 38.6 | 129,708 |
| 3 | za | 0.65 | 0.52/3.81 | 1.11/4.47 | 0.37/0.54 | 58.5 | 48.2 | 130,828 |
| 1 | zls | 55.0 | 0.51/1.18 | 1.25/6.89 | 0.43/0.92 | 5.3 | 59.4 | 71,960 |
| 2 | zls | 38.6 | 0.53/1.33 | 2.00/8.16 | 0.40/1.07 | 6.2 | 32.0 | 68,056 |
| 3 | zls | 48.1 | 0.52/0.75 | 1.88/4.04 | 0.36/0.71 | 5.4 | 29.8 | 67,840 |

Units: milliseconds for timings; KiB for RSS. `za` is zig-analyzer, `zls` is ZLS.

---

## Bottom line

Choose zig-analyzer when **semantic correctness, compiler-consistent diagnostics, safe refactoring, auto-import, and ZON/build integration** matter more than memory, binary size, and a 50 ms default diagnostic delay. Choose ZLS when **low resource use, a mature and simple server, immediate AstGen diagnostics, and a lightweight setup** matter more, and when the code is mostly ordinary Zig without heavy generic/comptime patterns.
