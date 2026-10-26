# zig-analyzer

English | [简体中文](README.zh-CN.md)

A language server (LSP) for Zig, built on an incremental query engine.

- **Diagnostics match the compiler**: errors come only from Zig itself (in-process AstGen while typing, `zig build` on save), never from guesses.
- **Real comptime evaluation**: generics and type constructors are evaluated, not pattern-matched; generic function bodies are analyzed with the instances from their call sites.
- **Build system integration**: the project model comes from the official build system protocol (`zig build --listen=-`), with no custom build runner. Files without `build.zig` fall back to single-file mode.
- **Fast on large codebases**: hover and completion stay within a few milliseconds on the Zig compiler source (540k lines plus std).

## Zig version

Zig **0.17.0**. Build zig-analyzer with the same Zig you use for your projects.

If the `zig` in `PATH` (or `zig.path`) is a different version, projects with `build.zig` are not loaded: there are no compiler diagnostics, and imports of named modules (dependencies, build options) are not resolved. Live diagnostics fall back to `zig ast-check`.

## Features

- **Diagnostics**
  - Live, while typing: syntax and AstGen errors.
  - On save: compiler errors from the build (the `check` step by default, or `diagnostics.steps`), with notes and reference traces.
  - Inactive code (opt-in, `diagnostics.inactive_code`): code that comptime knows is not compiled in the current build configuration is marked as unnecessary.
- **Navigation**: goto definition / declaration / type definition, find references, document highlight, document symbols, workspace symbols.
- **Editing**
  - Completion, including builtins with official documentation.
  - Hover, signature help.
  - Inlay hints: inferred types, field types in struct and union initializers, and parameter names (including builtins whose arguments are easy to confuse); single-argument calls and arguments that already carry the parameter's name (also behind `&`, `.*`, `.?`, `try`) are left unannotated.
  - Semantic tokens (full, delta, range), with unused bindings marked; optionally only the tokens that need semantic analysis (`semantic_tokens.mode = .partial`, to layer over the editor's syntax highlighting), and container-level `var`s marked `global`.
- **Refactoring**: rename (with prepare); code actions:
  - discard an unused name, or remove a pointless discard;
  - add missing switch prongs;
  - add missing struct fields;
  - extract an expression to a local constant;
  - organize imports: sort the top-level `@import` declarations (and declarations derived from them) into std / modules / files groups; auto-import adds new imports in the same order.
- **Formatting**: identical to `zig fmt`, for `.zig` and `.zon`.
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

Any LSP client works: run `zig-analyzer` over stdio.

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

Editor settings are read from `initializationOptions` and the `zig-analyzer` section of `workspace/configuration`. Every option is optional.

A `zig-analyzer.zon` in the project root shares project settings (build arguments, diagnostic steps, naming checks, import order) with the team; they take precedence over editor settings.

[`zig-analyzer.default.zon`](zig-analyzer.default.zon) lists every option with its default and what it does. Copy it as `zig-analyzer.zon` to start; the options only available in editor settings are listed in comments.

## Documentation

[`docs/design.md`](docs/design.md) (in Chinese) covers the architecture, performance targets and current measurements, and how correctness is verified.
