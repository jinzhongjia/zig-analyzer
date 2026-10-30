# zig-analyzer

A language server (LSP) for Zig, built on an incremental query engine.

- **Diagnostics match the compiler**: errors come only from Zig itself (in-process AstGen while typing, `zig build` on save), never from guesses.
- **Real comptime evaluation**: generics and type constructors are evaluated, not pattern-matched; generic function bodies are analyzed with the instances from their call sites.
- **Build system integration**: the project model comes from the official build system protocol (`zig build --listen=-`), with no custom build runner. Files without `build.zig` fall back to single-file mode.
- **Fast on large codebases**: hover and completion stay within a few milliseconds on the Zig compiler source (540k lines plus std).

## Zig version

Zig **0.17.0**. Build zig-analyzer with the same Zig you use for your projects.

If the `zig` in `PATH` (or `zig.path`) is a different version, projects with `build.zig` are not loaded: there are no compiler diagnostics, and imports of named modules (dependencies, build options) are not resolved. Live diagnostics fall back to `zig ast-check`.

The lib and global cache directories come from `zig env`; `zig.lib_path` and `zig.global_cache_path` override them. `zig.builtin_path` sets `@import("builtin")` for files outside any project.

## Features

- **Diagnostics**
  - Live, while typing: syntax and AstGen errors.
  - On save: compiler errors from the build (the `check` step by default, or `diagnostics.steps`), with notes and reference traces.
  - Inactive code (opt-in, `diagnostics.inactive_code`): code that comptime knows is not compiled in the current build configuration is marked as unnecessary.
- **Navigation**: goto definition / declaration / type definition, find references, document highlight, document symbols, workspace symbols.
- **Editing**
  - Completion: name completion ranks candidates by how well they match, ranking those whose type fits the expected type at the cursor (call arguments, typed declarations, `return`, field initializers, assignments, comparisons) higher, fuzzy-matches members of visible namespaces by their whole path (`memeql` → `std.mem.eql`), offers fields and callable methods of local values by their path (`gpa` → `sema.gpa`), and offers declarations and modules that are not imported yet (auto-import, on by default); items carry the kind of the symbol (namespace, struct, enum, method, type parameter, …); the selected function shows its signature and docs; builtins come with official documentation. With an editor that supports snippets, functions and builtins complete as calls with a placeholder for each argument (methods called on a value skip the receiver; nothing is added when `(` already follows), and common snippets are offered where a statement or declaration starts (`if`, `for`, `switch`, `print`, `fn`, `test`, `struct`, `main`, …).
  - Hover, signature help.
  - Inlay hints: inferred types, field types in struct and union initializers, and parameter names (including builtins whose arguments are easy to confuse); single-argument calls and arguments that already carry the parameter's name (also behind `&`, `.*`, `.?`, `try`) are left unannotated.
  - Semantic tokens (full, delta, range), with unused bindings marked; optionally only the tokens that need semantic analysis (`semantic_tokens.mode = .partial`, to layer over the editor's syntax highlighting), and container-level `var`s marked `global`.
- **Refactoring**: rename (with prepare); code actions:
  - discard an unused name, or remove a pointless discard;
  - remove an unused function parameter together with the matching argument at every call in the workspace, refusing with the reason when some use of the function cannot be updated;
  - remove an unused capture (`if (x) |v|` → `if (x != null)`, `catch |err|` → `catch`), or rename it to `_` where it cannot be removed;
  - change a local `var` that is never mutated to `const`;
  - add missing switch prongs;
  - add missing struct fields;
  - extract an expression to a local constant;
  - convert between string literals and multiline string literals, keeping the bytes;
  - organize imports: sort the top-level `@import` declarations (and declarations derived from them) into std / modules / files groups; auto-import adds new imports in the same order.
- **Formatting**: identical to `zig fmt`, for `.zig` and `.zon`.
- **ZON files**: the outline lists the fields; a `.zon` file imported with a result type (`const cfg: Config = @import("cfg.zon");`) gets the same field and enum-literal completion, goto and inlay hints as the same literal in Zig; `build.zig.zon` gets field completion with the official docs on hover, and completion and goto for its paths.
- **Structure**: folding ranges, selection ranges.
- **Naming checks** (opt-in): hints based on the [Names](https://ziglang.org/documentation/0.17.0/#Names) section of the Zig style guide, judged by what each declaration actually is (type, function, value), with rename fixes that refuse unsafe renames.

## Install

```sh
git clone https://github.com/jinzhongjia/zig-analyzer
cd zig-analyzer
zig build -Doptimize=ReleaseSafe
```

The binary is `zig-out/bin/zig-analyzer`. Put it in `PATH`, or point your editor at it.

## Editor setup

Any LSP client works: run `zig-analyzer` over stdio. The arguments clients commonly pass, `--stdio` and `--clientProcessId <pid>`, are accepted; other transports (`--pipe`, `--socket`, `--port`, `--node-ipc`) are not supported.

Neovim 0.11+:

```lua
vim.lsp.config('zig_analyzer', {
  cmd = { 'zig-analyzer' },
  filetypes = { 'zig', 'zon' },
  -- Match directory entries by their exact names. `root_markers = { 'build.zig', '.git' }` checks paths,
  -- which on case-insensitive file systems (macOS and Windows by default) also finds the standard
  -- library's `std/Build.zig` and makes the standard library directory a workspace root.
  root_dir = function(bufnr, on_dir)
    on_dir(vim.fs.root(bufnr, function(name) return name == 'build.zig' or name == '.git' end))
  end,
  settings = { ['zig-analyzer'] = {} },
})
vim.lsp.enable('zig_analyzer')
```

## Configuration

Editor settings are read from `initializationOptions` and the `zig-analyzer` section of `workspace/configuration`. Every option is optional. A section the client answers with `null` (not set in the editor) leaves the `initializationOptions` in effect.

A `zig-analyzer.zon` in the project root shares project settings (build arguments, diagnostic steps, naming checks, import order) with the team; they take precedence over editor settings.

[`zig-analyzer.default.zon`](zig-analyzer.default.zon) lists every option with its default and what it does. Copy it as `zig-analyzer.zon` to start; the options only available in editor settings are listed in comments.

## Documentation

[`docs/design.md`](docs/design.md) covers the architecture, performance targets and current measurements, and how correctness is verified.
