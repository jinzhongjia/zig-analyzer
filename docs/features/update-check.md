# Update check

The editor integrations tell the user when a newer server release exists. They never install one
by themselves: the existing install commands remain explicit, and every install verifies the
release's minisign signature and archive hash as before.

## The version file

`https://zig-analyzer.nvimer.org/latest.json` is a small JSON file:

```json
{ "schema": 1, "tag": "v0.1.2" }
```

- `tag` is a release tag, the same form that the install commands accept.
- `schema` lets the clients ignore a format they do not know.
- The file holds no download URLs, hashes, or install sources. A client only compares `tag` with
  the version of its running server and shows a message; a compromised version file can cause a
  spurious message, not an unsigned install.
- The file is served with `Cache-Control: public, max-age=300`.

The release workflow writes `updates/public/latest.json` in the runner and deploys it as a static
Workers asset after a stable release; the committed file is a sample for local preview. A
pre-release does not change the deployed file, so it always names the latest stable release. The
`updates` job reads `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from the `release`
environment; `updates/README.md` has the manual deploy command and the token's permissions.

Zed does not read the version file: its extension installs the latest release at the first server
start of a session when it manages the binary (see `editors/zed/README.md`). That is the one
integration that updates without a prompt.

## Version comparison

The server reports its version in `initialize` (`serverInfo.version`); `zig-analyzer --version`
prints the same value. The value is the tag without `v` when the build is exactly a release, and
can carry git information after it: `0.1.2+5.gabc1234` after the tag, `0.1.2-dev+d8b0905` before
it.

Clients compare as SemVer does:

- an optional leading `v` is ignored;
- build metadata after `+` is ignored;
- `major`, `minor`, and `patch` are compared as numbers;
- a pre-release (`0.2.0-rc.1`, `0.2.0-dev`) is older than the same release;
- pre-release identifiers compare as SemVer specifies (`alpha` < `alpha.1` < `alpha.10`).

Only a strictly newer `tag` is reported. An equal or older version, an unknown version, an invalid
file, and a failed download are silent; the server keeps working.

## When each client checks

| Client | Version source | When | State | Opt-out |
| --- | --- | --- | --- | --- |
| VS Code | `initializeResult.serverInfo.version` | at most once a day, after the server starts | `globalState` remembers the last check and the last reported tag | `zig-analyzer.server.checkUpdates: false` |
| Neovim | `client.server_info.version`, else the installed release's directory name | about 5 seconds after the first client attaches; once per session | the session remembers the reported tags | `setup({ check_updates = false })` |
| Vim | `--version` of the command the plugin starts | about 5 seconds after startup or the first Zig buffer; once per session | the session remembers the reported tags | `let g:zig_analyzer_check_updates = 0` |

A tag is reported once; a newer release is reported again. `:ZigAnalyzer checkUpdates` (Neovim and
Vim) checks on demand and reports even a tag that was reported before.

## Messages

- VS Code: an information message with **Release Notes** and, unless the server comes from
  `zig-analyzer.server.path`, **Install Server**. The latter opens the normal release picker; the
  install still verifies the release and restarts the server.
- Neovim: `vim.notify` with the release tag and `:ZigAnalyzer install`.
- Vim: `echomsg` with the release tag and `:ZigAnalyzer install`.

The message does not replace a server installed by a package manager or built from source by
itself. A server from `zig-analyzer.server.path` only gets the release notes link; a server from
`PATH` can be updated with its package manager as well.

## Tests

- `editors/vscode/test/unit.ts` checks the comparison, JSON parsing, and reading the file from the
  fake release server.
- `editors/nvim/test/update.lua` and `editors/vim/test/update.vim` check the same comparison
  table and the outcomes against `file://` version files.
- The `updates` CI job validates the committed JSON and bundles the Worker without deploying.
