# update check

`public/latest.json` is the version file that the VS Code, Neovim, and Vim integrations read to
learn whether a newer server release exists. It is served at
`https://zig-analyzer.nvimer.org/latest.json` and contains only a schema number and the release
tag:

```json
{ "schema": 1, "tag": "v0.1.2" }
```

The release workflow writes the file for a stable release and deploys it with Wrangler; the
committed file is a sample for local preview, and the deployed file is the source of truth. A
pre-release does not change it.

## Deploy by hand

```sh
npx --yes wrangler@4.163.0 deploy --config updates/wrangler.jsonc
```

`zig-analyzer.nvimer.org` must be a zone of the Cloudflare account, and the account needs a
`CLOUDFLARE_API_TOKEN` with Workers Scripts and Workers Routes edit access (and DNS edit access
for the custom domain). The release workflow reads `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` from the `release` environment. To preview the site locally:

```sh
npx --yes wrangler@4.163.0 dev --config updates/wrangler.jsonc
```
