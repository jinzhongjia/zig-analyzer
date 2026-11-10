# zig-analyzer for VS Code

Zig language support through the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer)
language server: diagnostics from the Zig compiler, comptime-aware completion, hover, goto,
references, rename, code actions, inlay hints, semantic highlighting, and `zig fmt` formatting,
for `.zig` and `.zon` files.

## Requirements

- `zig-analyzer` in `PATH`, or its path in `zig-analyzer.server.path`.
- Zig 0.17.0 or 0.17.1 in `PATH`, or its path in `zig-analyzer.zig.path`.

## The Zig extension and ZLS

The Zig extension (`ziglang.vscode-zig`) also starts ZLS for Zig files. When it is installed,
this extension offers to set `zig.zls.enabled` to `off`, so that only one language server answers.
Its other features (the Zig toolchain management, tasks, and debugging) keep working.

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
npm test                 # smoke test; ZIG_ANALYZER=<server> VSCODE_EXECUTABLE=<code> are optional
npm run package          # build zig-analyzer-<version>.vsix
```

On Linux without a display, run the test with `xvfb-run -a npm test`.
