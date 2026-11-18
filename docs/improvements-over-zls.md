# zig-analyzer: what it does better than ZLS

English | [简体中文](improvements-over-zls.zh-CN.md)

ZLS is a mature Zig language server. We compared ZLS 0.17.0 with zig-analyzer on two real projects and a small fixture. The numbers below are medians of three runs on Zig 0.17.1, with both servers built ReleaseSafe. The projects are ZLS's own source (37.6k lines, measured `src/analysis.zig`) and zig-analyzer's source (138.8k lines, measured `src/sema/infer.zig`).

## Diagnostics

ZLS's live diagnostics stop at AstGen. Sema errors require build-on-save, and build-on-save only starts automatically when `build.zig` declares a `check` step; otherwise the user has to turn it on, and without a `check` step it can only run the default step or skip the build.

zig-analyzer gets compiler diagnostics through the build system protocol (single-file mode for files without `build.zig`), so this does not depend on a `check` step. On a project without one, a semantic type error (`const n: u32 = "not a number";`) appeared in zig-analyzer after 1.31 s. ZLS published nothing in 10 s. With a `check` step, both reported it; ZLS was faster (383 ms vs 684 ms), but that path depends on the project's build file.

zig-analyzer's diagnostics also have a documented consistency definition: same file, positions, severity, message, notes and reference traces as `zig build` for the same contents, Zig version, step and arguments. ZLS has no equivalent definition; its diagnostic source is `zls`, and its compiler diagnostics come from the build-on-save path.

A type error or a missing field is exactly what the user wants after saving. A server that only sees AstGen by default does not cover that.

## Comptime and generics

In a fixture, `show(x: anytype)` is called with `Box(u64)` and reads `x.value`:

| Query | zig-analyzer | ZLS 0.17.0 |
|---|---|---|
| Hover on `x.value` | `value: u64`, with the call site | `null` |
| Completion after `x.` | `get`, `value` | `get` only |
| Goto on `value` | Field declaration in `Box` | `null` |
| Hover on `self.value` in `Box.get` | `value: u64` | `value: T` |
| Hover on `Chosen = if (builtin.os.tag == .linux) u32 else u64` | `type = u32` | Shows both `u32` and `u64` |

ZLS does resolve some call-site types: `identity(x: anytype)` called with `u32` shows `x: anytype` plus `(type = u32)`. The gap is member access on an `anytype` value, fields of a generic container, and comptime branch selection. These are common in the standard library, allocators, serialization, and compile-time configuration.

## Rename and references

`widget.zig` declares `pub fn resize(...)`; `main.zig` calls `w.resize(4)`. Requesting references/rename on the declaration:

| Metric | zig-analyzer | ZLS |
|---|---|---|
| References (including declaration) | 2 | 1 |
| Files edited by rename | 2 | 1 |
| `zig build check` after rename | Passes | Fails |

ZLS's failure:

```text
src/main.zig:38:6: error: no field or member function named 'resize' in 'widget.Widget'
    w.resize(4);
    ~^~~~~~~
```

The result was the same when `main.zig` was already open and the server had 5 s to settle. To isolate the rename, the test copy changes an unrelated `var never_mutated` to `const`; both servers are treated identically. ZLS did not find the cross-file method call and still returned a rename edit instead of refusing.

zig-analyzer refuses rename when a reference cannot be confirmed or the new name is ambiguous, and validates the renamed file with AstGen. A rename that silently leaves a call site behind turns a refactor into a build break.

## Completion and auto-import

zig-analyzer's completion is based on inference and name resolution. It offers names in scope, members of local values (including paths such as `sema.gpa`), auto-import candidates with the import edit, snippets, and `completionItem/resolve` for signatures and documentation.

ZLS has semantic completion and snippets, but no symbol auto-import. Its completion items do not carry `additionalTextEdits`, and in our runtime test an unimported `add` was never offered; zig-analyzer offered it with an import edit once its background index was ready.

Member-access completion recall:

| Project | zig-analyzer | ZLS |
|---|---|---|
| A (ZLS source) | 90/90 = 100% | 90/90 = 100% |
| B (zig-analyzer source) | 70/70 = 100% | 64/70 = 91.4% |

ZLS's misses on B were member accesses that needed cross-call/container type inference. The sample is small, but the deterministic fixture above shows the same direction.

## ZON

zig-analyzer treats `.zon` as a first-class file type: parsing, formatting and diagnostics for any `.zon` file; outline of the root expression; typed completion, goto and inlay hints for `.zon` files imported with a result type; `build.zig.zon` completion with the manifest schema; completion and option descriptions in `zig-analyzer.zon`; and a code action that runs `zig fetch` for a dependency URL and writes its hash.

ZLS formats `.zon` and has some syntax support, but several semantic features return `null` for `.zon` (signature help, inlay hints, references). A valid `build.zig.zon` produced 0 document symbols in our test; zig-analyzer produced 5 (`name`, `version`, `fingerprint`, `minimum_zig_version`, `paths`). Both formatters produced byte-identical output to `zig fmt` on an unformatted `.zig` and `.zon` file, so formatting is not the differentiator.

`build.zig.zon` is the project manifest. Editing it without schema completion, outline, or hash assistance is slower and easier to get wrong.

## Build system

zig-analyzer is a client of `zig build --listen=-` for the build graph, compile steps, modules, generated files, and compiler diagnostics. It maintains compile sets, analyzes shared files per compilation, resolves generated paths against the actual cache, and loads sub-projects (examples/benchmarks with their own `build.zig` and a `.path` dependency on the root).

ZLS also integrates with the build system, but its build configuration merges modules with the same root source file; the source comments call this a limitation. It has no equivalent sub-project loading mechanism in the version reviewed. In a project with a host tool and a cross-compiled target, or a library with examples, the same file can be compiled with different `builtin`/module settings; merging those contexts can produce incomplete or wrong navigation.

## Performance

Warm-path medians, three runs per cell. Project A is ZLS's `src/analysis.zig`, project B is zig-analyzer's `src/sema/infer.zig`.

| Metric | A: zig-analyzer | A: ZLS | B: zig-analyzer | B: ZLS |
|---|---|---|---|---|
| `initialize` | 0.67 ms | 19.1 ms | 0.83 ms | 48.1 ms |
| hover p50 / p95 | 0.37 / 1.91 ms | 0.58 / 1.31 ms | 0.52 / 3.42 ms | 0.52 / 1.18 ms |
| completion p50 / p95 | 0.44 / 3.85 ms | 0.79 / 4.16 ms | 0.91 / 2.71 ms | 1.88 / 6.89 ms |
| goto p50 / p95 | 0.23 / 0.46 ms | 0.52 / 1.04 ms | 0.37 / 0.54 ms | 0.40 / 0.92 ms |
| edit → diagnostics p50 | 56.2 ms | 6.0 ms | 58.2 ms | 5.4 ms |
| RSS | 127.1 MiB | 60.9 MiB | 127.8 MiB | 66.5 MiB |

The fixed 250-request CPU probe on project A:

| Metric | zig-analyzer | ZLS |
|---|---|---|
| Wall time | 244 ms | 341 ms |
| CPU time | 190 ms | 250 ms |
| CPU per request | 0.76 ms | 1.00 ms |

zig-analyzer is not faster everywhere. ZLS has the better hover tail on both projects and much faster default diagnostics. The advantages are the initialization handshake, goto/completion p50 (and usually p95), and CPU per request.

The 56–58 ms diagnostic number is mostly the default 50 ms debounce. With `diagnostics.debounce_ms = 0`, project A measured about 7 ms, close to ZLS's 6 ms. ZLS has no equivalent debounce setting.

## Protocol and configuration

zig-analyzer also provides `completionItem/resolve`, semantic-token delta, code-action resolve, the `zig-analyzer/packages` inspection request, and an `executeCommand` for fetching a dependency hash (when the client supports `workspace/applyEdit`). It has about 44 settings, nested JSON/ZON, and project settings in `zig-analyzer.zon`; ZLS has 22 flat settings and `zls.json`.

One capability that looks like a ZLS advantage is `willSaveWaitUntil`, but it is only a `force_autofix` fallback: disabled by default, manual saves only, and only `source.fixAll`. zig-analyzer instead exposes `source.fixAll` and `source.organizeImports` for the editor to run on save.

## Where ZLS is better

- **Memory:** 60.9 MiB vs 127.1 MiB on A, 66.5 MiB vs 127.8 MiB on B — about half. On a 40-line fixture: 14.4 MiB vs 49.0 MiB.
- **Binary size:** 20.1 MB vs 48.6 MB full; 3.5 MB vs 7.7 MB stripped.
- **Default diagnostics:** 5–6 ms vs 56–58 ms with the 50 ms debounce.
- **Hover tail on the larger project:** p95 1.18 ms vs 3.42 ms on B.
- **Semantic tokens on B:** 32.0 ms vs 38.6 ms.
- **Simplicity and maturity:** 22 flat settings vs about 44 nested settings; a long deployment history; a smaller surface to learn and operate.
- **Zig master:** ZLS master targets Zig 0.18.0-dev; zig-analyzer 0.2.1 targets Zig 0.17.0/0.17.1.

## How we measured

Each server ran three times per project. The client was a purpose-built LSP client over stdio; latency is end-to-end, including JSON serialization and client parsing. Warm measurements follow a 6 s settle and a warm-up pass. RSS is post-workload `VmRSS`, not peak. Edit-to-diagnostics used 2–3 syntax-error insertions per run.

There are limits. The machine is Linux x86-64 only; the projects are language-server/compiler infrastructure code with heavy generics; the samples are 30–180 per metric; and every round ran zig-analyzer first and ZLS second, which may give ZLS warmer file caches. ZLS was tested at the 0.17.0 tag, not the tip of 0.17.x. Performance tests disabled ZLS build-on-save while zig-analyzer's compiler diagnostics were on. The 15/15 diagnostic cross-check, 97-library batch, 10,305-file corpus and 372/372 formatting results in zig-analyzer's own docs are project-reported and were not independently reproduced here.

## Choosing

Use zig-analyzer when compiler-consistent diagnostics, comptime/generic resolution, safe rename, auto-import, ZON and build-model accuracy matter more than memory and binary size. Use ZLS when low resource use, a simple mature server, immediate AstGen diagnostics, or Zig master support matter more.
