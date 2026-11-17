# release server

Releases are served from `https://releases.zig-analyzer.dev`. The Worker reads two kinds of
objects from the private R2 bucket `zig-analyzer-releases`:

- `metadata.json`: the versions, their Zig compatibility, and their artifacts
- `releases/<tag>/<file>`: the signed archives and checksums of a release

The Worker is `updates/src/index.mjs`; `updates/wrangler.jsonc` binds the bucket and the custom
domain. The release workflow deploys the Worker and writes the objects; the client verifies every
download with the release key, so the Worker only handles availability and caching.

## Endpoints

| Path | Object |
| --- | --- |
| `/metadata.json` | `metadata.json` |
| `/latest/download/<file>` | 302 to `/download/<latest>/<file>` |
| `/download/<tag>/<file>` | `releases/<tag>/<file>` |

`metadata.json` is cached for 5 minutes; a tag-specific file is immutable for a year. The
`latest` redirect is cached for 5 minutes.

## metadata.json

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

`latest` is the newest stable tag; a pre-release stays in `versions` but does not become
`latest`. The file lists v0.1.1 and later; v0.1.0 has no signed `SHA256SUMS` and cannot be
installed. `zig.supported` comes from `supported_versions` in `src/project/ZigEnv.zig`;
`zig.packaging` is the Zig version the release workflow built with. `artifacts` lists the
archives of the release; the SHA-256 is in the signed `SHA256SUMS`, not duplicated here.

`updates/metadata.mjs` reads the existing file, adds the new version, sorts the versions, and
recomputes `latest`:

```sh
node updates/metadata.mjs \
  --tag v0.1.2 \
  --released 2026-11-16T00:00:00Z \
  --packaging-zig 0.17.1 \
  --artifacts dist \
  --existing old-metadata.json \
  --output metadata.json
```

Without `--existing`, the file starts with the new version. The CLI accepts `--supported-source`
(default `src/project/ZigEnv.zig`) and `--notes-base` (default the GitHub release URL).

## Local setup

`wrangler` must be logged in; `cf` is used for the Cloudflare account, DNS, and the CI token.

```sh
wrangler r2 bucket create zig-analyzer-releases
wrangler deploy --config updates/wrangler.jsonc
```

For a release, upload the artifacts first and `metadata.json` last:

```sh
for file in dist/*; do
  case "$file" in
    *.tar.gz) type=application/gzip ;;
    *.zip) type=application/zip ;;
    *) type=text/plain ;;
  esac
  wrangler r2 object put "zig-analyzer-releases/releases/v0.1.2/$(basename "$file")" \
    --file "$file" --content-type "$type" \
    --cache-control "public, max-age=31536000, immutable" --remote
done

wrangler r2 object put "zig-analyzer-releases/metadata.json" \
  --file metadata.json --content-type application/json \
  --cache-control "public, max-age=300" --remote
```

The release workflow does the same for each tag; `npx` is used there because the runner installs
Wrangler for that job.

## CI token

The release workflow reads `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from the `release`
environment. The token needs:

- Account: Workers Scripts: Edit
- Account: Workers R2 Storage: Edit
- Zone: Zone Read
- Zone: Workers Routes: Edit
- Zone: DNS: Edit

for the `zig-analyzer.dev` zone. `cf accounts tokens create` can create it; the value is stored as
the GitHub secret without being printed.

## Verify

```sh
curl -i https://releases.zig-analyzer.dev/metadata.json
curl -i https://releases.zig-analyzer.dev/latest/download/SHA256SUMS
curl -I https://releases.zig-analyzer.dev/download/v0.1.2/zig-analyzer-v0.1.2-x86_64-linux-ReleaseSafe.tar.gz
```
