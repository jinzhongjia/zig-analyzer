# zig-analyzer for Emacs

Emacs package for the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) Zig language
server: registers it with [Eglot](https://www.gnu.org/software/emacs/manual/html_node/eglot/) for
`.zig` and `.zon` files, starts Eglot automatically, and adds commands for the server's own
requests.

This directory is part of the [zig-analyzer repository](https://github.com/jinzhongjia/zig-analyzer);
report issues and send pull requests there.

## Requirements

- Emacs 29.1 or later (Eglot is built in).
- A Zig major mode: [`zig-mode`](https://melpa.org/#/zig-mode) or
  [`zig-ts-mode`](https://melpa.org/#/zig-ts-mode) from MELPA. Both cover `.zig` and `.zon`;
  `zig-ts-mode` needs Emacs 30.1+ and a tree-sitter Zig grammar.
- The server: see below.
- To install the server from a release: `curl`, `tar`, and
  [minisign](https://jedisct1.github.io/minisign/) in `PATH`.
- Zig 0.17.0 or 0.17.1 in `PATH`, or its path in the `zig.path` setting.

## Installation

Put this directory on `load-path` and enable the global minor mode:

```elisp
(add-to-list 'load-path "/path/to/zig-analyzer/editors/emacs")
(require 'zig-analyzer)
(zig-analyzer-mode 1)
```

With `use-package`:

```elisp
(use-package zig-analyzer
  :load-path "/path/to/zig-analyzer/editors/emacs"
  :config (zig-analyzer-mode 1))
```

`zig-analyzer-mode` registers the server with Eglot and calls `eglot-ensure` in `zig-mode` and
`zig-ts-mode` buffers. Without it, `M-x zig-analyzer-setup` only registers the server, and
`M-x eglot` starts it manually.

## Server

By default the server is the release installed by **M-x zig-analyzer-install-server**; when there
is none, `zig-analyzer` in `PATH`. `zig-analyzer-executable` overrides both, for example with a
server built from source:

```elisp
(setq zig-analyzer-executable "/path/to/zig-analyzer")
```

**M-x zig-analyzer-install-server** asks for the latest release or a tag such as `v0.1.1`, and for
the `ReleaseSafe` or `ReleaseFast` build. It downloads the release into
`zig-analyzer-install-directory`, checks the minisign signature of `SHA256SUMS` with
`zig-analyzer-public-key`, checks that the signature names the release, and checks the SHA-256 of
the archive before unpacking it. It then restarts the server of the current buffer with the new
release when `zig-analyzer-executable` is nil. The package downloads nothing on its own; only the
install command does. Releases go to `zig-analyzer-install-directory`
(`~/.local/share/emacs/zig-analyzer` by default, or
`%LOCALAPPDATA%\emacs\zig-analyzer` on Windows).

Set `zig-analyzer-minisign-executable` to nil to install without checking the signature (only the
SHA-256 is checked, with a warning). You can also install the server from a
[release](https://github.com/jinzhongjia/zig-analyzer/releases), Homebrew, the AUR, or Scoop, as
described in the repository README.

## Settings

`zig-analyzer-settings` is a plist with the structure of
[`zig-analyzer.default.zon`](https://github.com/jinzhongjia/zig-analyzer/blob/main/zig-analyzer.default.zon):

```elisp
(setq zig-analyzer-settings
      '(:build (:args ["-Dtarget=aarch64-linux"])
        :inlay_hints (:parameters :json-false)))
```

`.build = .{ .args = .{"-Dfoo"} }` is `(:build (:args ["-Dfoo"]))`, JSON arrays are vectors, and
JSON false is `:json-false`. Set the value before `zig-analyzer-mode`, or run
`M-x zig-analyzer-setup` and `M-x zig-analyzer-restart` after changing it. A `zig-analyzer.zon`
in the project root takes precedence over these settings.

## Commands

`M-x zig-analyzer-status`, `zig-analyzer-file-status`, `zig-analyzer-syntax-tree`, and
`zig-analyzer-module-graph` open a view with the server's answer; `q` closes it.
`zig-analyzer-install-server` downloads and installs a checked release,
`zig-analyzer-reload-workspace` reruns `build.zig` and reloads the projects,
`zig-analyzer-restart` restarts the server, and `zig-analyzer-show-log` opens the Eglot events
buffer.

Example key bindings:

```elisp
(with-eval-after-load 'zig-mode
  (define-key zig-mode-map (kbd "C-c z s") #'zig-analyzer-status)
  (define-key zig-mode-map (kbd "C-c z f") #'zig-analyzer-file-status)
  (define-key zig-mode-map (kbd "C-c z r") #'zig-analyzer-reload-workspace))
```

## lsp-mode

The package uses Eglot only. With `lsp-mode`, register `zig-analyzer` as a client for the `zig`
language and do not load `lsp-zig`, which starts ZLS. Eglot is the supported path.

## Test

From this directory, the unit tests need only Emacs:

```sh
emacs -Q --batch -L . -l test/zig-analyzer-test.el -f ert-run-tests-batch-and-exit
```

The install test creates fake releases in a temporary directory and signs them with the test key;
it needs Node, `minisign`, `curl`, and `tar`:

```sh
emacs -Q --batch -L . -l test/install.el
```

The smoke test opens a copy of `editors/test-project` and needs Zig 0.17 in `PATH`:

```sh
ZIG_ANALYZER=/path/to/zig-analyzer emacs -Q --batch -L . -l test/smoke.el
```
