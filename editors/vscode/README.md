# zig-analyzer for VS Code

Zig language support through the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer)
language server: diagnostics from the Zig compiler, comptime-aware completion, hover, goto,
references, rename, code actions, inlay hints, semantic highlighting, and `zig fmt` formatting,
for `.zig` and `.zon` files.

## Requirements

- `zig-analyzer` in `PATH`, or its path in `zig-analyzer.server.path`.
- Zig 0.17.0 or 0.17.1 in `PATH`, or its path in `zig-analyzer.zig.path`.

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
- **zig-analyzer: Reload Workspace**: rerun `build.zig` and reload the projects.
- **zig-analyzer: Show Server Status**, **Show File Status**, **Show Syntax Tree**,
  **Show Module Graph**: what the server knows, for reporting problems.

## Development

```sh
npm install
npm run typecheck
npm run check-settings   # package.json settings match src/server/Config.zig
npm test                 # smoke test on editors/test-project; ZIG_ANALYZER=<server> VSCODE_EXECUTABLE=<code> are optional
npm run package          # build zig-analyzer-<version>.vsix
```

The smoke test needs Zig 0.17 in `PATH`. On Linux without a display, run it with
`xvfb-run -a npm test`.
