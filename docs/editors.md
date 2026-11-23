# Editor setup

The server speaks LSP over standard input and output and is started as `zig-analyzer` with no
arguments. It handles `.zig` and `.zon` files, and needs Zig 0.17.0 or 0.17.1 in `PATH` or in
`zig.path`.

| Editor | Integration |
| --- | --- |
| VS Code | [Extension](../editors/vscode/README.md) |
| Zed | [Extension](../editors/zed/README.md), together with the Zig extension |
| Neovim 0.12+ | [Plugin](https://github.com/jinzhongjia/zig-analyzer.nvim), or `vim.lsp.config` below |
| Vim | [Plugin](https://github.com/jinzhongjia/zig-analyzer.vim) for yegappan/lsp or vim-lsp |
| Helix | [`languages.toml`](#helix) |
| Emacs | [Package](https://github.com/jinzhongjia/zig-analyzer.el) (eglot) |
| Sublime Text | [LSP package](#sublime-text) |
| Kate | [built-in LSP client](#kate) |
| JetBrains IDEs | [LSP4IJ](#jetbrains-ides-lsp4ij) |
| coc.nvim | [`coc-settings.json`](#cocnvim) |
| Other LSP clients | [generic setup](#other-clients) |

The dedicated integrations have their own READMEs; this page collects what users of every editor
need to know, including the editors that only need their own LSP client.

## Common requirements

- **Server.** Put `zig-analyzer` in `PATH`, or give its path in the editor's server setting. The
  release archives are described in the [README](../README.md#installation).
- **Zig.** Zig 0.17.0 or 0.17.1 from `PATH`, or `zig.path`. A project with `build.zig` is not
  loaded with another version; files outside a project still get single-file analysis.
- **Root.** The server uses the workspace folders the client sends, then `rootUri` or `rootPath`.
  For a project, that should be the nearest directory above the file containing `build.zig` or
  `.git`. Match these entry names exactly: on case-insensitive file systems (macOS and Windows by
  default), matching `build.zig` as a path also finds the standard library's `Build.zig` and makes
  the standard library directory a workspace root. Neovim's `root_markers` has this problem; the
  `root_dir` function in the example below does not.
- **Configuration.** The JSON structure is the one of
  [`zig-analyzer.default.zon`](../zig-analyzer.default.zon): `.build = .{ .args = .{"-Dfoo"} }`
  becomes `{ "build": { "args": ["-Dfoo"] } }`, and enum literals become strings. Send it in
  `initializationOptions` or in the `zig-analyzer` section of `workspace/configuration` and
  `workspace/didChangeConfiguration`. An outer `"zig-analyzer"` wrapper is accepted in both, and
  is usually what clients that key settings by server name expect.
- **Team settings.** `zig-analyzer.zon` in a project root overrides the project-related settings
  for everyone; editor-only settings (such as `zig.path`, `log`, and the file watcher choice)
  cannot be set there. See the comments in `zig-analyzer.default.zon`. For example:

  ```zig
  .{
      .build = .{ .args = .{"-Dtarget=aarch64-linux"} },
  }
  ```
- **Build step.** On save, the server runs `zig build <step>` and publishes the compiler's errors;
  files the step does not compile get only live diagnostics (syntax and AstGen). Without
  `diagnostics.steps`, the step is `check` when `build.zig` defines it, otherwise the default step
  (usually `install`, which also copies the artifacts to `zig-out`). A `check` step that depends
  on the compile steps, without installing or running them, keeps this fast; add the tests to it
  so their files are compiled too:

  ```zig
  const check = b.step("check", "Check that everything compiles");
  check.dependOn(&exe.step);
  check.dependOn(&tests.step);
  ```
- **`.zon` files.** The server handles them by extension. The editor only has to open them and
  attach its LSP client; some editors need `.zon` associated with the Zig file type by hand, and
  each section below says when.

## VS Code

The extension in [`editors/vscode`](../editors/vscode/README.md) starts the server, provides the
commands and status views, and can install a release of the server. It runs
`zig-analyzer.server.path` first, then the release installed by **zig-analyzer: Install Server**,
then `zig-analyzer` in `PATH`.

The Zig extension (`ziglang.vscode-zig`) is not required. If both extensions are enabled, each
starts its own server (ZLS and zig-analyzer) and both format Zig files; disable the Zig extension
unless you need it.

## Zed

Install the [Zig extension](https://zed.dev/extensions?query=Zig) and the
[zig-analyzer extension](../editors/zed/README.md) from Zed's extension page. The Zig extension
supplies the grammar, highlighting, and file types; the zig-analyzer extension starts the server.

```json
{
  "languages": {
    "Zig": {
      "language_servers": ["zig-analyzer", "!zls", "..."],
      "semantic_tokens": "combined"
    }
  },
  "lsp": {
    "zig-analyzer": {
      "binary": {
        "path": "/path/to/zig-analyzer"
      },
      "settings": {
        "build": { "args": ["-Dtarget=aarch64-linux"] },
        "semantic_tokens": { "mode": "partial" }
      }
    }
  }
}
```

The extension also downloads releases when `lsp.zig-analyzer.settings.download` selects one; see
its README for the details and for turning that off. ZLS must be turned off in
`language_servers` (the `!zls` entry); otherwise both run.

## Neovim

Use the [plugin](https://github.com/jinzhongjia/zig-analyzer.nvim), which registers the server,
adds `:ZigAnalyzer status`, `fileStatus`, `syntaxTree`, `moduleGraph`, `reloadWorkspace` and
`restart`, and can install releases:

```lua
vim.pack.add({ 'https://github.com/jinzhongjia/zig-analyzer.nvim' })
require('zig-analyzer').setup({
  -- cmd = { '/path/to/zig-analyzer' },
  settings = {
    build = { args = { '-Dtarget=aarch64-linux' } },
  },
})
```

Without the plugin, Neovim 0.12+ needs only `vim.lsp.config`:

```lua
vim.lsp.config('zig_analyzer', {
  cmd = { 'zig-analyzer' },
  filetypes = { 'zig', 'zon' },
  -- Match directory entries by their exact names. `root_markers = { 'build.zig', '.git' }`
  -- checks paths, which on case-insensitive file systems (macOS and Windows by default) also
  -- finds the standard library's `std/Build.zig` and makes the standard library directory a
  -- workspace root.
  root_dir = function(bufnr, on_dir)
    on_dir(vim.fs.root(bufnr, function(name) return name == 'build.zig' or name == '.git' end))
  end,
  settings = { ['zig-analyzer'] = {} },
})
vim.lsp.enable('zig_analyzer')
```

Neovim's built-in `vim.lsp` client shows semantic tokens, inlay hints, and code actions; start
with `:LspInfo` and `:checkhealth vim.lsp` when the server does not attach.

## Vim

The [plugin](https://github.com/jinzhongjia/zig-analyzer.vim) registers the server with
[yegappan/lsp](https://github.com/yegappan/lsp) (Vim 9) or
[vim-lsp](https://github.com/prabirshrestha/vim-lsp), whichever is loaded, and adds `:ZigAnalyzer`
for the server's own requests. Vim recognizes `.zig` and `.zon` as the `zig` filetype by itself.

```vim
let g:zig_analyzer_settings = {
      \ 'build': {'args': ['-Dtarget=aarch64-linux']},
      \ }
```

See `:help zig_analyzer`. The plugin runs `g:zig_analyzer_cmd` when it is set, else the release
installed by `:ZigAnalyzer install`, else `zig-analyzer` from `PATH`.

## Helix

Helix's built-in `zig` language already includes both `.zig` and `.zon`. Add this to
`~/.config/helix/languages.toml` (or `.helix/languages.toml` in a project):

```toml
[language-server.zig-analyzer]
command = "zig-analyzer"

# The config table is sent as initializationOptions.
[language-server.zig-analyzer.config]
build.args = ["-Dtarget=aarch64-linux"]

[[language]]
name = "zig"
language-servers = ["zig-analyzer"]
```

The `language-servers` list replaces the built-in `["zls"]`, so ZLS is not started. The built-in
`roots = ["build.zig"]` is left as is: Helix uses the topmost directory with a marker, so adding
`.git` would make the repository root win over a nested `build.zig`. Add `.git` only for
repositories without a `build.zig`. Inlay hints are off by default; enable them in
`~/.config/helix/config.toml`:

```toml
[editor.lsp]
display-inlay-hints = true
```

## Emacs (eglot)

The package in [`editors/emacs`](../editors/emacs/README.md) registers the server with
[Eglot](https://www.gnu.org/software/emacs/manual/html_node/eglot/), starts it in `zig-mode` and
`zig-ts-mode` buffers, finds the `build.zig`/`.git` project root (also from a file in `src`), and
adds commands for the server's own requests:

```elisp
(package-vc-install
 '(zig-analyzer . (:url "https://github.com/jinzhongjia/zig-analyzer.el")))
(require 'zig-analyzer)
(setq zig-analyzer-settings
      '(:build (:args ["-Dtarget=aarch64-linux"])))
(zig-analyzer-mode 1)
```

The repository is a read-only mirror; the package is developed in `editors/emacs`. For a local
checkout, add `editors/emacs` to `load-path` instead of `package-vc-install`.

Install [`zig-mode`](https://melpa.org/#/zig-mode) (covers `.zig` and `.zon`) or
[`zig-ts-mode`](https://melpa.org/#/zig-ts-mode) (Emacs 30.1+ with a tree-sitter Zig grammar)
from MELPA. The package uses the release installed by **M-x zig-analyzer-install-server**, else
`zig-analyzer` in `PATH`; set `zig-analyzer-executable` to use another server. The install command
checks the release's minisign signature and SHA-256 and needs `minisign`, `curl`, and `tar`.
`M-x zig-analyzer-status`, `zig-analyzer-file-status`, `zig-analyzer-syntax-tree`,
`zig-analyzer-module-graph`, and `zig-analyzer-reload-workspace` show the server's answers.

Without the package, Eglot needs this configuration. Current Eglot versions have a built-in entry
that starts ZLS for these modes; `add-to-list` puts the zig-analyzer entry first:

```elisp
(require 'zig-mode)  ; or (require 'zig-ts-mode)

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((zig-mode zig-ts-mode)
                 "zig-analyzer"
                 :initializationOptions
                 (:build (:args ["-Dtarget=aarch64-linux"])))))
```

Settings can also be given per project with `eglot-workspace-configuration`; the server pulls the
`zig-analyzer` section when the client supports `workspace/configuration`. `M-x eglot` starts the
server in a Zig or ZON buffer; add `(add-hook 'zig-mode-hook #'eglot-ensure)` (or
`zig-ts-mode-hook`) to start it automatically.

## Sublime Text

Install the [LSP](https://packagecontrol.io/packages/LSP) and
[Zig Language](https://packagecontrol.io/packages/Zig%20Language) packages from Package Control.
Add the server in **Preferences → Package Settings → LSP → Server Configurations**
(`Packages/User/LanguageServers.sublime-settings`):

```json
{
  "zig-analyzer": {
    "enabled": true,
    "command": ["zig-analyzer"],
    "selector": "source.zig | source.zon",
    "settings": {
      "zig-analyzer": {
        "build": { "args": ["-Dtarget=aarch64-linux"] }
      }
    }
  }
}
```

`settings` is returned for `workspace/configuration` and sent on changes, so the wrapper is the
`zig-analyzer` section the server asks for. The current Zig Language syntax assigns Zig to `.zon`
as well; if `.zon` files open as plain text, select the Zig syntax for them or install the current
syntax from the package's repository. LSP uses the folders of the current Sublime project (or
window) as the workspace, so open the project directory itself.

## Kate

Kate has a built-in LSP client; enable it in **Settings → Configure Kate → Plugins → LSP Client**
if necessary. Then open **Settings → Configure Kate → LSP Client → User Server Settings** and add:

```json
{
  "servers": {
    "zig": {
      "highlightingModeRegex": "^Zig$",
      "servers": {
        "zig-analyzer": {
          "command": ["zig-analyzer"],
          "rootIndicationFileNames": ["build.zig", ".git"],
          "settings": {
            "zig-analyzer": {
              "build": { "args": ["-Dtarget=aarch64-linux"] }
            }
          },
          "url": "https://github.com/jinzhongjia/zig-analyzer"
        },
        "zls": { "disabled": true }
      }
    }
  }
}
```

`settings` is used for both `workspace/configuration` and `workspace/didChangeConfiguration`;
`rootIndicationFileNames` finds the project root. `zls` is disabled because Kate's built-in Zig
entry starts it by default.

Kate's Zig highlighting mode covers `*.zig` only. To use the server for a `.zon` file, assign it
the Zig mode in **Tools → Highlighting → Sources → Zig**.

## JetBrains IDEs (LSP4IJ)

Install the [LSP4IJ](https://plugins.jetbrains.com/plugin/23257-lsp4ij) plugin, then open
**Settings → Languages & Frameworks → LSP4IJ** and create a user-defined language server with
**+**:

- **Server:** name `zig-analyzer`, command `zig-analyzer` (or its absolute path). LSP4IJ starts it
  over stdio.
- **Mappings:** add file name patterns `*.zig` and `*.zon`; use `zig` as the language ID for both.
- **Configuration tab:** put the `zig-analyzer` section in **Configuration**:

  ```json
  {
    "zig-analyzer": {
      "build": { "args": ["-Dtarget=aarch64-linux"] }
    }
  }
  ```

- **Workspace Folders:** the IDE's project roots are used by default. To make every directory
  with `build.zig` or `.git` its own root, use marker-based discovery:

  ```json
  { "markers": ["build.zig", ".git"] }
  ```

LSP4IJ does not add syntax highlighting. A syntax-only Zig plugin (for example the
[Zig](https://plugins.jetbrains.com/plugin/10560-zig) plugin) can be used for that. ZigBrains also
runs ZLS; do not run it and zig-analyzer on the same files. LSP4IJ's **LSP console** shows the
server's stderr and trace and can restart it.

## coc.nvim

coc.nvim can start the server from `coc-settings.json` (open it with `:CocConfig`). Vim and
Neovim already recognize `.zon` as the `zig` filetype.

```json
{
  "languageserver": {
    "zig-analyzer": {
      "command": "zig-analyzer",
      "filetypes": ["zig", "zon"],
      "rootPatterns": ["build.zig", ".git"],
      "settings": {
        "zig-analyzer": {
          "build": { "args": ["-Dtarget=aarch64-linux"] }
        }
      }
    }
  }
}
```

`initializationOptions` is also supported by coc.nvim; either form accepts the outer
`zig-analyzer` wrapper. `:CocCommand workspace.showOutput` shows the server's output when it does
not start.

## Other clients

Any LSP client can run the server; no client-side extension is required. The client needs to:

- start `zig-analyzer` over stdio (it accepts `--stdio` and ignores it; `--pipe`, `--socket`,
  `--port`, and `--node-ipc` are rejected);
- open `.zig` and `.zon` files with language IDs `zig` and `zon`;
- send a workspace folder or root URI for the project. The root should be the nearest directory
  above the file with `build.zig` or `.git`, matched by exact entry name;
- pass settings in `initializationOptions` (directly or under `"zig-analyzer"`), and, when it
  supports them, answer `workspace/configuration` for section `zig-analyzer` and send
  `workspace/didChangeConfiguration`.

The server implements `zig-analyzer/status`, `zig-analyzer/fileStatus`,
`zig-analyzer/syntaxTree`, `zig-analyzer/moduleGraph`, `zig-analyzer/reloadWorkspace`, and
`zig-analyzer/waitIdle` (used by tests). It has no `workspace/executeCommand`, so a client that
can only trigger custom requests through commands cannot expose the status and debug views.

## Troubleshooting

- **The server does not start.** Run `zig-analyzer` in a terminal and check its stderr; then check
  the editor's LSP log. Set a log file in the settings:

  ```json
  { "log": { "level": "debug", "file": "/tmp/zig-analyzer.log" } }
  ```

- **No project diagnostics.** Check the Zig version (`zig version`); 0.17.0 and 0.17.1 are the
  supported versions for projects with `build.zig`. In the dedicated integrations,
  `zig-analyzer/status` and `zig-analyzer/fileStatus` show what the server knows about the root
  and the file.
- **The wrong directory became the root.** A case-insensitive file system can match
  `std/Build.zig` for a `build.zig` path pattern. Configure the client's root markers by exact
  entry name (as in the Neovim example) and reopen the file.
- **Two servers run.** ZLS and zig-analyzer both provide Zig diagnostics and formatting. Turn off
  ZLS in the editor or in the other Zig extension (the sections above show where); Zed, Helix,
  Kate, and Emacs all have a default ZLS entry that needs to be disabled or replaced.
- **`.zon` files have no server.** The editor must map them to Zig or to a ZON language. Kate and
  Sublime Text have notes above; with other clients, add `.zon` to the Zig file types.
- **Settings do not apply.** Most clients pass a server-keyed object
  (`{ "zig-analyzer": { ... } }`) as the section; `initializationOptions` also accepts the inner
  object directly. A `zig-analyzer.zon` in the project root overrides client settings, and some
  settings are editor-only and ignored there.
