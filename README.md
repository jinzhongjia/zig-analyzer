# zig-analyzer

English | [简体中文](README.zh-CN.md)

A language server (LSP) for Zig, built on an incremental query engine.

## Features

- **Diagnostics**: errors come only from Zig itself, using in-process AstGen while typing and `zig build` on save. Inactive code can optionally be marked.
- **Comptime evaluation**: generics and type constructors are evaluated, and generic function bodies are analyzed with the instances from their call sites.
- **Build system integration**: the project model comes from the official build system protocol. Files without `build.zig` use single-file mode.
- **Navigation**: goto definition / declaration / type definition, find references, document highlight, document and workspace symbols.
- **Editing**: completion with auto-import and snippets, hover, signature help, inlay hints, and semantic tokens.
- **Refactoring**: rename and code actions for unused names, parameters, and captures, `var` to `const`, missing switch prongs and struct fields, extracting constants, converting string literals, and organizing imports.
- **Formatting**: identical to `zig fmt`, for `.zig` and `.zon`.
- **ZON files**: highlighting, formatting, and error diagnostics in any `.zon` file; outline; completion, goto, and inlay hints for files imported with a result type and for `build.zig.zon`; completion and option descriptions in `zig-analyzer.zon`.
- **Structure**: folding ranges and selection ranges.
- **Naming checks** (opt-in): hints based on the [Names](https://ziglang.org/documentation/0.17.1/#Names) section of the Zig style guide, with safe rename fixes.

## Editor support

| Editor | Integration |
| --- | --- |
| VS Code | Extension in [`editors/vscode`](editors/vscode) |
| Zed | Extension in [`editors/zed`](editors/zed) (with the Zig extension) |
| Neovim 0.12+ | Plugin in [`editors/nvim`](editors/nvim) |
| Vim | Plugin in [`editors/vim`](editors/vim), for yegappan/lsp or vim-lsp |

Without the Neovim plugin, Neovim 0.12+ needs only:

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

## Development

Requires Zig **0.17.0** or **0.17.1**.

```sh
zig build -Doptimize=ReleaseSafe  # build zig-out/bin/zig-analyzer
zig build test                    # run the tests that need no external tools
zig build test-all                # run all tests, including those that run the zig in PATH
```

Options are listed in [`zig-analyzer.default.zon`](zig-analyzer.default.zon). The design is described in [`docs/design.md`](docs/design.md).

## License

[MIT](LICENSE)
