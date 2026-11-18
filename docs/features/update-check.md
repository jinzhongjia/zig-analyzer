# Update check and release distribution

The editor integrations tell the user when a newer server release exists and install a release
only when the user asks. The server binaries and their metadata are served from
`https://releases.zig-analyzer.dev`; GitHub keeps the release pages, the Homebrew and AUR updates,
and the build provenance.

## Release server

A Worker with the private R2 bucket `zig-analyzer-releases` serves two kinds of objects:

| URL | Object |
| --- | --- |
| `/metadata.json` | `metadata.json` |
| `/latest/download/<file>` | 302 to `/download/<latest>/<file>` |
| `/download/<tag>/<file>` | `releases/<tag>/<file>` |

`metadata.json` is cached for 5 minutes; a tag-specific file is immutable for a year. The Worker
sets `Access-Control-Allow-Origin: *` so the `zig-analyzer.dev` site can read the metadata.

`metadata.json` holds every release:

```json
{
  "schema": 1,
  "latest": "v0.1.2",
  "versions": [
    {
      "tag": "v0.1.2",
      "released": "2026-11-16T00:00:00Z",
      "prerelease": false,
      "zig": {
        "supported": ["0.17.0", "0.17.1"],
        "packaging": "0.17.1"
      },
      "artifacts": [
        {
          "target": "x86_64-linux",
          "optimize": "ReleaseSafe",
          "file": "zig-analyzer-v0.1.2-x86_64-linux-ReleaseSafe.tar.gz",
          "size": 11427679
        }
      ],
      "notes": "https://github.com/jinzhongjia/zig-analyzer/releases/tag/v0.1.2"
    }
  ]
}
```

- `latest` is the newest stable tag; a pre-release is listed in `versions` with
  `"prerelease": true` and does not become `latest`.
- `zig.supported` comes from `supported_versions` in `src/project/ZigEnv.zig`; `zig.packaging` is
  the Zig version the release workflow built with.
- `artifacts` lists the archives of the release. The SHA-256 is in the signed `SHA256SUMS`, not
  duplicated here.
- `notes` is a link for the user; it is not a download source.

The release workflow writes the objects for each tag. It uploads the archives and checksums
first, then merges the release into `metadata.json` through `updates/metadata.mjs`, then publishes
the GitHub release. The metadata merge keeps the previous versions and recomputes `latest`, so a
failed upload never points users at a missing archive. `updates/README.md` has the local commands
and the Worker's token permissions.

## Install

The install commands download from the release server, never from GitHub:

1. `GET /latest/download/SHA256SUMS` and `/latest/download/SHA256SUMS.minisig`, or the same two
   files under `/download/<tag>/` for a given tag.
2. Verify the minisign signature with the release key (`minisign.pub` in the repository root,
   built into the integrations). The trusted comment gives the tag; when the user chose a tag, it
   must match.
3. `GET /download/<tag>/<archive>` for the archive of the system and optimize mode.
4. Verify the SHA-256 against `SHA256SUMS`.
5. Run the downloaded server with `--version`, install it, and restart.

The Worker is not trusted for authenticity: a compromised Worker or R2 object cannot produce an
archive that passes the signature and hash checks. It can only cause a failed install.

## Update check

The update check reads `metadata.json` and compares `latest` with the running server. The version
is the tag without `v` when the build is exactly a release, and can carry git information:
`0.1.2+5.gabc1234` after the tag, `0.1.2-dev+d8b0905` before it.

Clients compare as SemVer does:

- an optional leading `v` is ignored;
- build metadata after `+` is ignored;
- `major`, `minor`, and `patch` are compared as numbers;
- a pre-release (`0.2.0-rc.1`, `0.2.0-dev`) is older than the same release;
- pre-release identifiers compare as SemVer specifies (`alpha` < `alpha.1` < `alpha.10`).

Only a strictly newer `latest` is reported. An equal or older version, an unknown version, an
invalid file, and a failed download are silent; the server keeps working.

### When each client checks

| Client | Version source | When | State | Opt-out |
| --- | --- | --- | --- | --- |
| VS Code | `initializeResult.serverInfo.version` | at most once a day, after the server starts | `globalState` remembers the last check and the last reported tag | `zig-analyzer.server.checkUpdates: false` |
| Neovim | `client.server_info.version`, else the installed release's directory name | about 5 seconds after the first client attaches; once per session | the session remembers the reported tags | `setup({ check_updates = false })` |
| Vim | `--version` of the command the plugin starts | about 5 seconds after startup or the first Zig buffer; once per session | the session remembers the reported tags | `let g:zig_analyzer_check_updates = 0` |

A tag is reported once; a newer release is reported again. `:ZigAnalyzer checkUpdates` (Neovim and
Vim) checks on demand and reports even a tag that was reported before.

### Messages

- VS Code: an information message with **Release Notes** and, unless the server comes from
  `zig-analyzer.server.path`, **Install Server**. The latter opens the normal release picker; the
  install still verifies the release and restarts the server.
- Neovim: `vim.notify` with the release tag and `:ZigAnalyzer install`.
- Vim: `echomsg` with the release tag and `:ZigAnalyzer install`.

The message does not replace a server installed by a package manager or built from source by
itself. A server from `zig-analyzer.server.path` only gets the release notes link; a server from
`PATH` can be updated with its package manager as well.

Zed installs and updates from the same release server, but does not read `metadata.json`: its
extension installs the latest release at the first server start of a session when it manages the
binary (see `editors/zed/README.md`). That is the one integration that updates without a prompt.

## Tests

- `updates/test/metadata.test.mjs` checks the metadata merge, version order, artifact names, and
  the supported Zig versions.
- `updates/test/worker.test.mjs` checks the Worker routes, redirects, caching headers, and errors.
- `editors/vscode/test/unit.ts` checks the comparison, metadata parsing, and reading it from the
  fake release server.
- `editors/nvim/test/update.lua` and `editors/vim/test/update.vim` check the same comparison table
  and the outcomes against `file://` metadata files.
- The `updates` CI job runs the tests and bundles the Worker with `wrangler deploy --dry-run`
  without deploying.
