# zig-analyzer for VS Code

Zig language support through the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer)
language server: diagnostics from the Zig compiler, comptime-aware completion, hover, goto,
references, rename, code actions, inlay hints, semantic highlighting, and `zig fmt` formatting,
for `.zig` and `.zon` files.

## Requirements

- The server: see below.
- Zig 0.17.0 or 0.17.1 in `PATH`, or its path in `zig-analyzer.zig.path`.

## The server

The extension runs `zig-analyzer.server.path` when it is set, else the release installed by
**zig-analyzer: Install Server**, else `zig-analyzer` from `PATH`. It downloads nothing by itself:
**Install Server** asks for the latest release (built with ReleaseSafe or ReleaseFast) or a tag
such as `v0.1.1`, downloads it from
[GitHub](https://github.com/jinzhongjia/zig-analyzer/releases) into the extension's global storage,
and restarts the running server with it. When the server cannot start, the error message offers to
run it.

Before an install, the minisign signature of the release's `SHA256SUMS` must verify with the
zig-analyzer release key and its trusted comment must name the release, and the archive must have
the SHA-256 that `SHA256SUMS` lists for it.

## The Zig extension and ZLS

If the Zig extension (`ziglang.vscode-zig`) is installed, it starts its own language server, ZLS,
for Zig files, and you would get results from both servers. This extension offers to turn ZLS off
(`zig.zls.enabled: "off"`). Only ZLS is turned off: the Zig extension's other features, such as
installing Zig, build tasks, and run and debug, keep working.

## Settings

The server settings are the options of
[`zig-analyzer.default.zon`](https://github.com/jinzhongjia/zig-analyzer/blob/main/zig-analyzer.default.zon),
under `zig-analyzer.`: `.build = .{ .args = .{"-Dfoo"} }` there is
`"zig-analyzer.build.args": ["-Dfoo"]` here. Only the settings you set are sent to the server;
`zig-analyzer.zon` in the project root takes precedence over them.

Settings of the extension itself:

- `zig-analyzer.server.path`: the server executable.
- `zig-analyzer.server.extraEnv`: extra environment variables of the server.
- `zig-analyzer.trace.server`: log the LSP messages to the `zig-analyzer` output channel.

## Commands

Click the `zig-analyzer` status bar item, or run from the command palette:

- **zig-analyzer: Restart Server**
- **zig-analyzer: Install Server**: download a release of the server (see above).
- **zig-analyzer: Reload Workspace**: rerun `build.zig` and reload the projects.
- **zig-analyzer: Show Server Status**, **Show File Status**, **Show Syntax Tree**,
  **Show Module Graph**: what the server knows, for reporting problems. In a view, Go to
  Definition (Ctrl/Cmd-click) follows a line: it opens a file, goes to the module an import refers
  to, or goes to a node or token of the syntax tree in the source file. The cursor's line in the
  syntax tree highlights its range in the source file.

## Development

```sh
npm install
npm run typecheck
npm run check-settings   # package.json settings match src/server/Config.zig
npm test                 # unit tests, smoke test, Install Server test; ZIG_ANALYZER=<server> VSCODE_EXECUTABLE=<code> are optional
npm run package          # build zig-analyzer-<version>.vsix
```

The smoke test opens a copy of `editors/test-project` and needs Zig 0.17 in `PATH`; the test of
Install Server installs fake releases of the server from a local server, and needs `tar`. The
tests run on macOS and Linux; on Linux without a display, run them with `xvfb-run -a npm test`.
