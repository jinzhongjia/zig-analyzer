# zig-analyzer for Zed

Starts the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) language server for Zig and
ZON files. The Zig language itself (grammar, highlighting, file types) comes from the Zig
extension, which must be installed too.

## Requirements

- The Zig extension.
- The server: `zig-analyzer` in `PATH`, its path in `lsp.zig-analyzer.binary.path`, or else a
  release that the extension downloads (see [Server](#server)).
- Zig 0.17.0 or 0.17.1 in `PATH` (the server sees the PATH of your login shell), or its path in
  the `zig.path` server setting.

## Installation

Install zig-analyzer from Zed's extensions page (`zed: extensions`). To try a local checkout, run
`zed: install dev extension` and select this directory (`editors/zed`); Zed builds it with the Rust
toolchain from rustup.

## Server

The extension starts the first of:

1. `lsp.zig-analyzer.binary.path`, when it is set;
2. `zig-analyzer` in `PATH`;
3. the release that the extension installs.

The `download` setting selects the release; when it is `true` or an object, the release starts
even with a server in `PATH`:

```json
{
  "lsp": {
    "zig-analyzer": {
      "settings": { "download": { "version": "v0.1.1", "optimize": "ReleaseFast" } }
    }
  }
}
```

No `download`, or `true`, selects the ReleaseSafe build of the latest release; an object selects
another one, where `version` is `"latest"` (the default) or a release tag, and `optimize` is
`"ReleaseSafe"` (the default) or `"ReleaseFast"`. `false` turns downloads off, leaving only
`binary.path` and `PATH`. The extension reads the setting itself and does not send it to the
server.

The release is installed when the server starts (when a Zig file is opened, or on
`editor: restart language server`); Zed shows "Checking for updates to zig-analyzer" and
"Downloading zig-analyzer" meanwhile:

- For the latest release, the extension downloads its `SHA256SUMS` at the first server start of a
  Zed session to learn which release it is, and installs it when that is not the installed one.
- For a given tag, an installed release needs no network; another one is installed.

A release is installed only when the minisign signature of its `SHA256SUMS` verifies with the
release key (`minisign.pub` in the repository root, built into the extension), the trusted comment
of the signature names the release (`zig-analyzer <tag>`), and the archive has the SHA-256 that
`SHA256SUMS` lists for it. The archive is downloaded from the tag that the signature names, so a
new latest release in between cannot be mixed in. Only regular files and directories below the
release directory are unpacked. Releases without a signed `SHA256SUMS` (v0.1.0) cannot be
installed.

When an install fails, the server does not start and Zed shows the error, so that a release that
does not verify is never passed over. The exception is a latest release that cannot be downloaded
(when offline, say): then the installed release starts.

Releases go into the extension's work directory, `server/<release>/` with `server/current` naming
the one in use; the others are removed after an install. The work directory is
`~/Library/Application Support/Zed/extensions/work/zig-analyzer` on macOS,
`$XDG_DATA_HOME/zed/extensions/work/zig-analyzer` (`~/.local/share/zed/...`) on Linux, and
`%LOCALAPPDATA%\Zed\extensions\work\zig-analyzer` on Windows. Downloads go through Zed, with its
proxy settings; the `granted_extension_capabilities` setting must allow `download_file` from
`github.com` (the default allows all downloads).

## Settings

The Zig extension starts ZLS for the same files. To use only zig-analyzer, put it first and turn
ZLS off in `settings.json`. Zed requests semantic tokens only when `semantic_tokens` is not
`"off"` (the default): `"combined"` adds them on top of the tree-sitter highlighting, and pairs
with the server's `semantic_tokens.mode` set to `"partial"`; `"full"` uses only them.

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
        "semantic_tokens": { "mode": "partial" },
        "inlay_hints": { "parameters": false }
      }
    }
  }
}
```

`settings` holds the options of
[`zig-analyzer.default.zon`](https://github.com/jinzhongjia/zig-analyzer/blob/main/zig-analyzer.default.zon)
written as JSON (`.build = .{ .args = .{"-Dfoo"} }` is `{ "build": { "args": ["-Dfoo"] } }`, enum
literals are strings). They are sent at startup and whenever they change. `zig-analyzer.zon` in the
project root takes precedence over them. `binary.arguments` and `binary.env` are also supported.

## Development

```sh
cargo test
cargo build --release --target wasm32-wasip2
```

`cargo test` checks the settings, the unpacking (archives of the `tar` crate and, when there is a
`tar` command, of the system tar), and installs from fake releases signed with a test key, plus the
signature of the real v0.1.1 `SHA256SUMS` (`test/fixtures`).
