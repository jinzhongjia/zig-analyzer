# zig-analyzer compared with ZLS

English | [简体中文](improvements-over-zls.zh-CN.md)

Versions: ZLS 0.17.0 ([`542462c`][zls]) and zig-analyzer 0.2.1, both built ReleaseSafe, on Zig 0.17.1. Measurements were taken on two projects and a small fixture: project A is ZLS's source (37.6k lines, measured in `src/analysis.zig`), project B is zig-analyzer's source (138.8k lines, measured in `src/sema/infer.zig`). Numbers are medians of three runs. Statements about ZLS behavior link to its source at that commit.

[zls]: https://github.com/zigtools/zls/tree/542462c4ddf045493fa9ca028ee6bc3f38b2754a

## Diagnostics

ZLS's live diagnostics run AstGen only ([`diagnostics.zig:30-58`][zls-diag]). Sema errors come from build-on-save. Build-on-save is on by default where Zig supports file watching ([`Server.zig:781`][zls-bos]), but when `enable_build_on_save` is not set explicitly it only runs a `check` step; if `build.zig` has none, it does not build ([`bsp.zig:1088-1094`][zls-check]).

zig-analyzer gets compiler diagnostics through `zig build --listen=-` (single-file mode for files outside a build), with or without a `check` step. The published diagnostics match `zig build` for the same contents, Zig version, step and arguments: file, position, severity, message, notes and reference traces ([`diagnostics.md`](diagnostics.md)).

Writing `const n: u32 = "not a number";` in a project without a `check` step:

| | zig-analyzer | ZLS |
|---|---|---|
| Without `check` step | Reported after 1.31 s | Nothing within 10 s |
| With `check` step | 684 ms | 383 ms |

[zls-diag]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/diagnostics.zig#L30-L58
[zls-bos]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/Server.zig#L780-L784
[zls-check]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/bsp.zig#L1088-L1094

## Comptime and generics

Fixture: `show(x: anytype)` is called with a `Box(u64)` and reads `x.value`.

| Query | zig-analyzer | ZLS |
|---|---|---|
| Hover on `x.value` | `value: u64`, with the call site | `null` |
| Completion after `x.` | `get`, `value` | `get` |
| Goto on `value` | Field declaration in `Box` | `null` |
| Hover on `self.value` in `Box.get` | `value: u64` | `value: T` |
| Hover on `Chosen = if (builtin.os.tag == .linux) u32 else u64` | `type = u32` | Both `u32` and `u64` |

ZLS does infer some call-site types: for `identity(x: anytype)` called with a `u32` it shows `x: anytype` and `(type = u32)`. It misses member access on `anytype` values, fields of generic containers, and comptime branch selection.

## Rename and references

`widget.zig` declares `pub fn resize(...)`, `main.zig` calls `w.resize(4)`. References and rename are requested on the declaration:

| | zig-analyzer | ZLS |
|---|---|---|
| References (including the declaration) | 2 | 1 |
| Files edited by rename | 2 | 1 |
| `zig build check` after rename | Passes | Fails |

```text
src/main.zig:38:6: error: no field or member function named 'resize' in 'widget.Widget'
    w.resize(4);
    ~^~~~~~~
```

The result is the same with `main.zig` open and 5 s to settle. The test copy changes an unrelated `var never_mutated` to `const` so the build only fails on the rename; both servers ran on the same copy.

zig-analyzer refuses a rename when a reference cannot be confirmed or the new name conflicts, and checks the renamed file with AstGen ([`features/references-rename.md`](features/references-rename.md)).

## Completion and auto-import

ZLS completion items carry no `additionalTextEdits` (the name does not appear in its `src/`), so it cannot insert an import. In the runtime test an unimported `add` was never offered by ZLS; zig-analyzer offered it with the import edit once its background index was ready ([`features/auto-import.md`](features/auto-import.md)).

Member-access completion recall:

| Project | zig-analyzer | ZLS |
|---|---|---|
| A | 90/90 (100%) | 90/90 (100%) |
| B | 70/70 (100%) | 64/70 (91.4%) |

ZLS's six misses on B all need type inference across calls or through containers.

## ZON

ZLS returns `null` for `.zon` files in hover, goto, completion, references, signature help, inlay hints, document symbols and code actions ([`hover.zig:506`][zon-hover], [`goto.zig:292`][zon-goto], [`completions.zig:1042`][zon-comp], [`references.zig:741`][zon-refs], [`signature_help.zig:29`][zon-sig], [`inlay_hints.zig:163`][zon-inlay], [`document_symbol.zig:26`][zon-sym], [`code_actions.zig:39`][zon-ca]). It formats `.zon` and produces semantic tokens for it.

zig-analyzer provides for `.zon`: diagnostics, formatting and outline for any file; typed completion, goto and inlay hints for files imported with a result type; schema completion in `build.zig.zon` and `zig-analyzer.zon`; and a code action that runs `zig fetch` for a dependency URL and writes the hash. A valid `build.zig.zon` gives 5 document symbols (`name`, `version`, `fingerprint`, `minimum_zig_version`, `paths`).

Both formatters produce output byte-identical to `zig fmt` on the test `.zig` and `.zon` files.

[zon-hover]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/hover.zig#L506
[zon-goto]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/goto.zig#L292
[zon-comp]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/completions.zig#L1042
[zon-refs]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/references.zig#L741
[zon-sig]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/signature_help.zig#L29
[zon-inlay]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/inlay_hints.zig#L163
[zon-sym]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/document_symbol.zig#L26
[zon-ca]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/code_actions.zig#L39

## Build system

ZLS merges modules that share a root source file: "All modules with the same root source file are merged. This limitation may be lifted in the future." ([`bsp.zig:25`][zls-merge]). A file compiled both for a host tool and for a cross-compiled target, or with different module imports, is analyzed under one merged context.

zig-analyzer keeps each compilation separate and analyzes a shared file per compilation, resolves generated files against the actual cache, and loads sub-projects (directories with their own `build.zig` that depend on the root by `.path`, such as examples) on demand ([`design.md`](design.md#sub-projects)). ZLS 0.17.0 has no equivalent of sub-project loading.

[zls-merge]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/bsp.zig#L25

## Performance

Warm path, median of three runs per cell:

| | A: zig-analyzer | A: ZLS | B: zig-analyzer | B: ZLS |
|---|---|---|---|---|
| `initialize` | 0.67 ms | 19.1 ms | 0.83 ms | 48.1 ms |
| hover p50 / p95 | 0.37 / 1.91 ms | 0.58 / 1.31 ms | 0.52 / 3.42 ms | 0.52 / 1.18 ms |
| completion p50 / p95 | 0.44 / 3.85 ms | 0.79 / 4.16 ms | 0.91 / 2.71 ms | 1.88 / 6.89 ms |
| goto p50 / p95 | 0.23 / 0.46 ms | 0.52 / 1.04 ms | 0.37 / 0.54 ms | 0.40 / 0.92 ms |
| edit → diagnostics p50 | 56.2 ms | 6.0 ms | 58.2 ms | 5.4 ms |
| semantic tokens | | | 38.6 ms | 32.0 ms |
| RSS | 127.1 MiB | 60.9 MiB | 127.8 MiB | 66.5 MiB |

A fixed sequence of 250 requests on A:

| | zig-analyzer | ZLS |
|---|---|---|
| Wall time | 244 ms | 341 ms |
| CPU time | 190 ms | 250 ms |
| CPU per request | 0.76 ms | 1.00 ms |

zig-analyzer's edit → diagnostics time is mostly its default 50 ms debounce (`diagnostics.debounce_ms`). With it set to 0, A measures about 7 ms. ZLS has no debounce.

## Protocol and configuration

zig-analyzer also implements `completionItem/resolve`, semantic token deltas, `codeAction/resolve`, the `zig-analyzer/packages` request, and an `executeCommand` that fetches a dependency hash. It has 44 settings in nested sections, read from editor settings or `zig-analyzer.zon` ([`src/server/Config.zig`](../src/server/Config.zig)). ZLS has 22 flat settings in `zls.json` ([`Config.zig`][zls-config]).

ZLS advertises `willSaveWaitUntil`, but only uses it when `force_autofix` is enabled (off by default), only for manual saves, and only for AstGen fixes ([`Server.zig:268-283`][zls-autofix], [`Server.zig:1210-1219`][zls-wswu]). zig-analyzer provides `source.fixAll` and `source.organizeImports` code actions for editors to run on save.

[zls-config]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/Config.zig
[zls-autofix]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/Server.zig#L268-L283
[zls-wswu]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/Server.zig#L1210-L1219

## Where ZLS is better

- Memory: about half (60.9 vs 127.1 MiB on A, 66.5 vs 127.8 MiB on B, 14.4 vs 49.0 MiB on a 40-line fixture).
- Binary size: 20.1 vs 48.6 MB, stripped 3.5 vs 7.7 MB.
- Live AstGen diagnostics: 5-6 ms vs 56-58 ms with the default debounce.
- Hover p95: 1.31 vs 1.91 ms on A, 1.18 vs 3.42 ms on B.
- Semantic tokens on B: 32.0 vs 38.6 ms.
- Fewer settings (22 vs 44) and a longer deployment history.
- Zig master: ZLS master requires Zig 0.18.0-dev ([`build.zig.zon`](https://github.com/zigtools/zls/blob/master/build.zig.zon)); zig-analyzer 0.2.1 supports Zig 0.17.x.

## Method

A dedicated LSP client drove each server over stdio; latencies are end to end, including JSON encoding and decoding. Warm measurements start after a 6 s settle and one warm-up pass. RSS is `VmRSS` after the workload, not the peak. Edit → diagnostics inserts 2-3 syntax errors per run. Each metric has 30-180 samples.

Limits:

- Linux x86-64 only.
- Both projects are compiler/language-server code with heavy use of generics.
- zig-analyzer always ran first in each round, so ZLS may have had warmer file caches.
- ZLS build-on-save was off in the performance runs; zig-analyzer's compiler diagnostics were on.
