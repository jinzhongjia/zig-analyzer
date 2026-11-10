# Plan: editor support research

Decide, for each mainstream editor, what zig-analyzer users need beyond the server binary (a
plugin, an upstream configuration entry, or only documentation), and what the server and the
release process must provide for it.

Integrations in `editors/`: VS Code, Zed, Neovim, and Vim (yegappan/lsp and vim-lsp). They find
`zig-analyzer` in PATH or a configured path; none downloads binaries or manages the Zig toolchain.

## What the server offers a client today

These facts constrain every integration and are the baseline of the research.

- Transport: stdio only (`--stdio` is accepted and ignored; `--pipe`, `--socket`, `--port`, and
  `--node-ipc` are rejected). `--clientProcessId` and `initialize.processId` make the server exit
  with its client.
- Languages: `.zig` and `.zon`. Root detection must match `build.zig` / `.git` by exact entry name
  (see the README: path matching on case-insensitive file systems finds `std/Build.zig`).
- Toolchain: needs Zig 0.17.0 or 0.17.1 (`zig` in PATH or `zig.path`); projects with `build.zig`
  are not loaded with another version.
- Configuration: JSON in `initializationOptions` and in the `zig-analyzer` section of
  `workspace/configuration` (pulled when the client supports it, with dynamic
  `didChangeConfiguration` registration), plus `zig-analyzer.zon` in the project root, which takes
  precedence. The option set is documented in `zig-analyzer.default.zon`; there is no JSON Schema.
- Capability negotiation: UTF-8 position encoding when offered, otherwise UTF-16; work-done
  progress, semantic token and inlay hint refresh, `codeAction/resolve`, snippets,
  insert/replace edits, markdown, hierarchical symbols, and change annotations are used only
  when the client declares them.
- File watching: dynamic `workspace/didChangeWatchedFiles` registration when the client supports
  it; otherwise (and always outside the workspace folders) native OS watchers. No client is
  required to watch files.
- Semantic tokens: only standard token types and modifiers, plus the custom modifier `global`;
  full, delta, and range requests.
- Custom requests: `zig-analyzer/status`, `zig-analyzer/fileStatus`, `zig-analyzer/syntaxTree`,
  `zig-analyzer/moduleGraph`, `zig-analyzer/reloadWorkspace` (and `zig-analyzer/waitIdle`, used by
  tests). No `workspace/executeCommand`, code lens, or custom notifications to the client.
- Distribution: `build.zig.zon` version is `0.0.0`; CI builds and tests on Linux, macOS, and
  Windows but publishes no release artifacts. Users build from source.

## Editors in scope

| Editor | Integration model | Existing Zig support | Starting hypothesis |
| --- | --- | --- | --- |
| VS Code (and VSCodium, Cursor, Windsurf via Open VSX) | Extension (TypeScript, `vscode-languageclient`) | `ziglang.vscode-zig` (official, bundles ZLS management) | Needs an extension; largest user base |
| Neovim 0.12+ | `vim.lsp.config` | Built-in filetype | Documentation only (no plugin planned); evaluate an `nvim-lspconfig` config entry |
| Zed | Extension (Rust compiled to WASM) | `zed-industries/zed` Zig extension, starts ZLS | Needs an extension or an upstream change to the Zig extension |
| Helix | `languages.toml` | Built-in Zig language, ZLS default | Documentation; evaluate an upstream `languages.toml` server entry |
| Emacs | eglot (built in) / lsp-mode | `zig-mode`, `zig-ts-mode` | Documentation for eglot; evaluate an lsp-mode client |
| JetBrains IDEs | LSP4IJ (all IDEs) or the platform LSP API | ZigBrains (bundles ZLS) | Evaluate LSP4IJ user-defined server vs. a plugin |
| Sublime Text | `LSP` package client config | `Zig Language` package | Documentation; evaluate an `LSP-zig-analyzer` helper package |
| Kate, Vim (vim-lsp / coc.nvim / ALE) | Configuration | Varies | Documentation only |

## Research questions

For each editor in scope, answer the following and record the answers in a single matrix.

1. Language registration: does the editor know `.zig` and `.zon` files (`.zon` is often not
   associated with Zig), and does it provide syntax highlighting the server's partial semantic
   tokens can rely on?
2. Server acquisition: can the integration find `zig-analyzer` in PATH, take a configured path,
   or download a release binary? What do comparable servers (rust-analyzer, clangd, ZLS) do in
   that editor?
3. Root and workspace folders: how does the editor pick the root, does it send
   `workspaceFolders`, and does it hit the case-insensitive `std/Build.zig` problem?
4. Configuration: does it send `initializationOptions`, answer `workspace/configuration`, and
   support dynamic `didChangeConfiguration` registration? Can users write nested JSON settings?
   Can the extension offer completion or validation (a JSON Schema generated from
   `zig-analyzer.default.zon`)?
5. Capabilities actually declared: capture the `initialize` request of each client (the server's
   log file shows it) and compare it with the list above: position encoding, semantic token
   refresh and delta, inlay hint refresh, code action resolve, snippets, work-done progress,
   watched files registration, change annotations.
6. Feature rendering: semantic tokens (theme mapping for the `global` modifier and for
   `defaultLibrary`), inlay hints, code action kinds (`source.organizeImports`,
   `source.fixAll`), rename with `prepareRename`, progress display, `window/showMessage`
   warnings for configuration errors.
7. Custom requests: can the integration expose `status` (status bar), `reloadWorkspace`
   (command), `syntaxTree` and `moduleGraph` (debug views)? Which of them are worth a UI?
8. Coexistence with ZLS: if the existing Zig extension starts ZLS, can users disable it, and can
   that extension start another server instead? Would its maintainers accept an option for
   alternative servers, or is a separate extension the only way?
9. Known client defects that affect us (in the manner of
   `docs/neovim-semantic-tokens-race.md`).
10. Publishing: marketplace requirements, signing, review time, update mechanism, and the
    maintenance cost of each integration (language and build tooling, release cadence of the
    editor API).

## Method

- Capability capture: start each editor against a debug build with `log_file` set, open the same
  sample project (a `build.zig` project with a `.zon` import and a single file outside it), and
  save the `initialize` request and the first minutes of traffic.
- Feature walk-through: per editor, check each item in `docs/features/*.md` once (completion,
  goto, references, rename, code actions, inlay hints, semantic tokens, formatting, outline,
  folding) and record what works, what is missing, and why (client support or server behavior).
- Existing ecosystem review: read how `vscode-zig`, ZigBrains, and Zed's Zig extension launch
  ZLS, manage its binary, and pass settings; read rust-analyzer's integrations as the reference
  for a server with its own extension and custom requests.
- No plugin code in this phase except throwaway prototypes needed to answer a question.

## Deliverables

- `docs/editors.md` (or a section of `design.md`): the client capability matrix and the
  per-editor setup instructions that need no plugin; the README links to it.
- A recommendation per editor: plugin, upstream configuration entry, or documentation only, with
  priority and estimated maintenance cost.
- The server-side prerequisites the selected integrations need, for example:
  - release artifacts (Linux, macOS, Windows; x86_64 and aarch64) with checksums and a stable
    download URL scheme, and a real version number;
  - a JSON Schema of the editor settings, generated from the same source as
    `zig-analyzer.default.zon`;
  - any custom request or `workspace/executeCommand` that a UI needs.
- External issue records for client defects found during the research.

## Steps

- [x] VS Code extension (`editors/vscode`), with a smoke test in a real VS Code.
- [x] Zed extension (`editors/zed`), tried in Zed 1.27 with the Zig extension 0.4.2.
- [x] Neovim plugin (`editors/nvim`), with a headless smoke test.
- [x] Vim plugin (`editors/vim`) for yegappan/lsp and vim-lsp; with a smoke test for each client.
- [ ] Prepare the sample project and a debug build with logging.
- [ ] Capture `initialize` and walk through features in VS Code.
- [ ] Same for Zed.
- [ ] Same for Helix.
- [ ] Same for Emacs (eglot; lsp-mode if eglot shows gaps).
- [ ] Same for JetBrains with LSP4IJ.
- [ ] Same for Sublime Text and Kate.
- [ ] Re-check Neovim 0.12 against the same checklist (documentation only).
- [ ] Review how existing Zig extensions manage ZLS; decide coexistence strategy per editor.
- [ ] Write the matrix and recommendations; list server-side prerequisites.
- [ ] Decide which plugins to build and open a plan for each, starting with the release
      pipeline if any plugin downloads binaries.

## Open questions

- Should plugins download release binaries, or only find a user-installed `zig-analyzer`? This
  decides whether the release pipeline comes first.
- Should a plugin also manage the Zig toolchain (as `vscode-zig` does), or leave that to the
  user and existing tools?
- Is a separate VS Code extension acceptable, or should the first attempt be an alternative
  server option in `vscode-zig`?
