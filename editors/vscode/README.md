# zig-analyzer for VS Code

Zig language support through the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer)
language server: diagnostics from the Zig compiler, comptime-aware completion, hover, goto,
references, rename, code actions, inlay hints, semantic highlighting, and `zig fmt` formatting,
for `.zig` and `.zon` files; and running, debugging, and testing with `zig`.

## Requirements

- The server: see below.
- Zig 0.17.0 or 0.17.1 in `PATH`, or its path in `zig-analyzer.zig.path`.

## The server

The extension runs `zig-analyzer.server.path` when it is set, else the release installed by
**zig-analyzer: Install Server**, else `zig-analyzer` from `PATH`. It installs nothing by itself:
**Install Server** asks for the latest release (built with ReleaseSafe or ReleaseFast) or a tag
such as `v0.1.1`, downloads it from the zig-analyzer release server
(`https://releases.zig-analyzer.dev`) into the extension's global storage, and restarts the running
server with it. When the server cannot start, the error message offers to run it.

## Updates

Once a day, after the server starts, the extension reads the release metadata
(`https://releases.zig-analyzer.dev/metadata.json`). When its latest release is newer than the
running server, a message says so and offers the release notes and **Install Server**; nothing is
downloaded or installed unless you choose it. A failed check is silent. Set
`zig-analyzer.server.checkUpdates` to `false` to turn the check off.

Before an install, the minisign signature of the release's `SHA256SUMS` must verify with the
zig-analyzer release key and its trusted comment must name the release, and the archive must have
the SHA-256 that `SHA256SUMS` lists for it.

## The Zig extension

This extension does not need the Zig extension (`ziglang.vscode-zig`). With both enabled, Zig files
get diagnostics and formatting from each: the Zig extension starts its own language server, ZLS,
runs `zig ast-check` on every edit when ZLS is off, and makes itself the default formatter. This
extension offers to open it in the Extensions view, where you can disable it.

Unlike the Zig extension, this extension does not install Zig.

## Running, debugging, and tests

- **zig-analyzer: Run** and the **Run** code lens above `pub fn main` run `zig build run` in the
  project of the file (the nearest directory above it with a `build.zig`), and `zig run <file>` for
  a file outside any project.
- **zig-analyzer: Debug** and the **Debug** code lens build the executable and start the debugger
  of `zig-analyzer.debug.adapter` on it: in a project, the executable `zig build` installs; else
  the file's.
- The named tests of the open Zig files are in the Testing view and have a run button in the
  gutter. A test runs as `zig test <file> --test-filter <name>`, so a file that imports the modules
  of its `build.zig` cannot be tested this way.
- The `$zig` problem matcher reads the errors of `zig build` in tasks.

## Settings

The server settings are the options of
[`zig-analyzer.default.zon`](https://github.com/jinzhongjia/zig-analyzer/blob/main/zig-analyzer.default.zon),
under `zig-analyzer.`: `.build = .{ .args = .{"-Dfoo"} }` there is
`"zig-analyzer.build.args": ["-Dfoo"]` here. Only the settings you set are sent to the server;
`zig-analyzer.zon` in the project root takes precedence over them.

Settings of the extension itself:

- `zig-analyzer.server.path`: the server executable.
- `zig-analyzer.server.extraEnv`: extra environment variables of the server.
- `zig-analyzer.server.checkUpdates`: check for a newer server release once a day.
- `zig-analyzer.trace.server`: log the LSP messages to the `zig-analyzer` output channel.
- `zig-analyzer.debug.adapter`: the debugger type to launch; `lldb` is the CodeLLDB extension.

## Commands

Click the `zig-analyzer` status bar item, or run from the command palette:

- **zig-analyzer: Restart Server**
- **zig-analyzer: Install Server**: download a release of the server (see above).
- **zig-analyzer: Reload Workspace**: rerun `build.zig` and reload the projects.
- **zig-analyzer: Run**, **zig-analyzer: Debug**: see above.
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
