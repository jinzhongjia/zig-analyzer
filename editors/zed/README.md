# zig-analyzer for Zed

Starts the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) language server for Zig and
ZON files. The Zig language itself (grammar, highlighting, file types) comes from the Zig
extension, which must be installed too.

## Requirements

- The Zig extension.
- `zig-analyzer` in `PATH`, or its path in `lsp.zig-analyzer.binary.path`.
- Zig 0.17.0 or 0.17.1 in `PATH` (the server sees the PATH of your login shell), or its path in
  the `zig.path` server setting.

## Installation

Until the extension is published: run `zed: install dev extension` and select this directory
(`editors/zed`). Zed builds it with the Rust toolchain from rustup.

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
