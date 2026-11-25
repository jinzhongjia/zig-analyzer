<p align="center">
  <img src="assets/logo.png" alt="zig-analyzer" width="220">
</p>

# zig-analyzer

English | [简体中文](README.zh-CN.md)

A language server (LSP) for Zig, built on an incremental query engine. Website: [zig-analyzer.dev](https://zig-analyzer.dev).

## Features

- **Diagnostics**: errors come only from Zig itself, using in-process AstGen while typing and `zig build` on save. Inactive code can optionally be marked.
- **Comptime evaluation**: generics and type constructors are evaluated, and generic function bodies are analyzed with the instances from their call sites.
- **Build system integration**: the project model comes from the official build system protocol. Files without `build.zig` use single-file mode.
- **Navigation**: goto definition / declaration / type definition, find references, document highlight, document and workspace symbols.
- **Editing**: completion with auto-import and snippets, hover, signature help, inlay hints, and semantic tokens.
- **Refactoring**: rename and code actions for unused names, parameters, and captures, `var` to `const`, missing switch prongs and struct fields, extracting constants, converting string literals, and organizing imports.
- **Formatting**: identical to `zig fmt`, for `.zig` and `.zon`.
- **ZON files**: highlighting, formatting, and error diagnostics in any `.zon` file; outline; completion, goto, and inlay hints for files imported with a result type and for `build.zig.zon`; completion and option descriptions in `zig-analyzer.zon`; a code action that fetches the hash of a dependency URL with `zig fetch`.
- **Structure**: folding ranges and selection ranges.
- **Naming checks** (opt-in): hints based on the [Names](https://ziglang.org/documentation/0.17.1/#Names) section of the Zig style guide, with safe rename fixes.
- **Unused declarations** (opt-in): hints on private declarations that no code in the same file reaches, including helpers used only by other unused declarations.
- **Lint hints** (opt-in): redundant `@as` / `@intCast` / `@truncate` / `@floatCast` (with a fix that removes them), comparisons that the range of an integer type decides (`x < 256` for a `u8`), and `errdefer` statements that never run; given only when they hold under every build configuration.
- **Hint suppressions**: comments such as `// zig-analyzer-disable-next-line: naming` silence analyzer hints for a line or a range; diagnostics from Zig itself are never affected.

## Editor support

| Editor | Integration |
| --- | --- |
| VS Code | Extension in [`editors/vscode`](editors/vscode) |
| Zed | Extension in [`editors/zed`](editors/zed) (with the Zig extension) |
| Neovim 0.12+ | Plugin [zig-analyzer.nvim](https://github.com/jinzhongjia/zig-analyzer.nvim), developed in [`editors/nvim`](editors/nvim) |
| Vim | Plugin [zig-analyzer.vim](https://github.com/jinzhongjia/zig-analyzer.vim), developed in [`editors/vim`](editors/vim), for yegappan/lsp or vim-lsp |
| Helix | `languages.toml`, see [docs/editors.md](docs/editors.md#helix) |
| Emacs | Package [zig-analyzer.el](https://github.com/jinzhongjia/zig-analyzer.el), developed in [`editors/emacs`](editors/emacs) (eglot) |
| Sublime Text | LSP package, see [docs/editors.md](docs/editors.md#sublime-text) |
| Kate | Built-in LSP client, see [docs/editors.md](docs/editors.md#kate) |
| JetBrains IDEs | LSP4IJ, see [docs/editors.md](docs/editors.md#jetbrains-ides-lsp4ij) |
| coc.nvim | `coc-settings.json`, see [docs/editors.md](docs/editors.md#cocnvim) |

Setup for these editors, the settings they share, and the requirements for any other LSP client is
in [`docs/editors.md`](docs/editors.md).

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

## Installation

On macOS and Linux, with [Homebrew](https://brew.sh):

```sh
brew install jinzhongjia/tap/zig-analyzer
```

On Arch Linux (x86_64 and aarch64), from the AUR, with an AUR helper such as yay: [`zig-analyzer-bin`](https://aur.archlinux.org/packages/zig-analyzer-bin) installs the release archive, [`zig-analyzer`](https://aur.archlinux.org/packages/zig-analyzer) builds the release from source with the `zig` package:

```sh
yay -S zig-analyzer-bin
```

On Windows (x86_64 and aarch64), with [Scoop](https://scoop.sh):

```pwsh
scoop bucket add jin https://github.com/jinzhongjia/scoop-bucket
scoop install jin/zig-analyzer
```

Each installs the ReleaseSafe build of the latest release, with its debug information; `brew upgrade`, `yay -Syu`, or `scoop update zig-analyzer` updates it. The tap and the AUR packages are updated when a release is published, the Scoop bucket within a few hours. Pre-releases are in none of them. The Emacs package can install a checked release with `M-x zig-analyzer-install-server`; see [`editors/emacs`](editors/emacs).

Each [release](https://github.com/jinzhongjia/zig-analyzer/releases) has an archive per platform (x86_64 and aarch64 on Linux, macOS, and Windows) in two builds:

| Build | Use |
| --- | --- |
| `ReleaseSafe` | Recommended. Safety checks stay on: a bug stops the server with a stack trace in the log instead of producing wrong results, and the editor restarts it. Include the log when reporting a crash. |
| `ReleaseFast` | Safety checks off, somewhat faster. A bug may produce wrong results or crash without a trace. |

Put `zig-analyzer` (`zig-analyzer.exe` on Windows) in `PATH`, or point the editor integration at it. Keep `zig-analyzer.dSYM` (macOS) or `zig-analyzer.pdb` (Windows) next to the executable: it holds the debug information that gives stack traces file names and line numbers.

The archives and `SHA256SUMS` are signed with [minisign](https://jedisct1.github.io/minisign/). Verify with the public key in [`minisign.pub`](minisign.pub), using `minisign` or [`minizign`](https://github.com/jedisct1/zig-minisign):

```sh
minisign -Vm zig-analyzer-<version>-<target>-ReleaseSafe.tar.gz -p minisign.pub
minizign -V -p minisign.pub -m zig-analyzer-<version>-<target>-ReleaseSafe.tar.gz
```

Each archive also has a build provenance attestation, which shows that the release workflow of this repository built it from the tagged commit:

```sh
gh attestation verify zig-analyzer-<version>-<target>-ReleaseSafe.tar.gz --repo jinzhongjia/zig-analyzer
```

Versions with a suffix (`0.2.0-rc.1`) are pre-releases. Changes between versions are listed in [`CHANGELOG.md`](CHANGELOG.md).

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
