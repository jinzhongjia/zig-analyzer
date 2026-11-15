---
name: release-vscode
description: Release a new version of the zig-analyzer VS Code extension (editors/vscode version bump, annotated tag editors/vscode/vX.Y.Z, published to the VS Code Marketplace and Open VSX by .github/workflows/vscode-publish.yml). Use when asked to release, publish, or bump the VS Code extension; for the server itself use the release skill.
---

# Release the VS Code extension

A release of the extension is an annotated tag `editors/vscode/vX.Y.Z` on `main`, with `X.Y.Z`
the `version` in `editors/vscode/package.json`. The extension is versioned independently of the
server. Pushing the tag runs `.github/workflows/vscode-publish.yml`:

1. The tag is annotated, on `main`, and matches `package.json`.
2. `npm ci`, `npm run typecheck`, `npm run check-settings`, and `vsce package`; the `.vsix` is kept
   as an artifact of the run.
3. `vsce publish --oidc` publishes the `.vsix` to the VS Code Marketplace (publisher
   `jinzhongjia`) through trusted publishing: no token, the Marketplace trusts the workflow file
   `vscode-publish.yml` of this repository.
4. `ovsx publish` publishes the same `.vsix` to Open VSX (namespace `jinzhongjia`), also through
   trusted publishing: the trusted publisher registered for the namespace names this repository
   and `vscode-publish.yml`.

Both publish steps pass `--skip-duplicate`: a version that a registry has already is skipped, so
rerunning the workflow after one registry failed publishes to the other.

The tag does not start with `v`, so the server's `release.yml`, the `Release tags` ruleset, and the
`release` environment (all `v*`) do not apply to it. A version published to the Marketplace cannot
be published again.

Ask the user before each step that is visible to others: pushing to `main`, opening or merging the
version pull request, and pushing the tag.

## 1. Preconditions

```sh
git switch main && git pull --ff-only
git status --short          # clean, apart from untracked local files
gh auth status
git tag -l 'editors/vscode/v*' --sort=-v:refname | head -n 1    # the last release; none before the first
npx --yes @vscode/vsce@4 show jinzhongjia.zig-analyzer --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).versions[0].version))'
```

The last tag and the Marketplace version should agree (before the first release there is neither:
`vsce show` prints `undefined`); if they do not, tell the user before going on.

## 2. Choose the version

Read the changes to the extension since the last release:

```sh
git log --first-parent --oneline <last tag>..main -- editors/vscode
```

Semantic versioning: while the major version is 0, a minor bump for changes users must act on
(settings removed or renamed, a newer VS Code required, a server version required) or for notable
new features, a patch bump otherwise. Changes outside `editors/vscode` (the server) do not need an
extension release. Propose the version with the reason and let the user decide. Check the tag
does not exist: `git ls-remote --tags origin 'editors/vscode/vX.Y.Z'`.

## 3. Bump the version

```sh
cd editors/vscode
npm version X.Y.Z --no-git-tag-version    # package.json and package-lock.json
npm ci && npm run typecheck && npm run check-settings && npx vsce package --no-dependencies -o "$TMPDIR/zig-analyzer.vsix"
```

Commit both files on a branch as `editors/vscode: release vX.Y.Z` and open a pull request with
the `internal` label. Merge it when CI passes, then `git switch main && git pull --ff-only`.

## 4. Tag and push

```sh
git tag -a editors/vscode/vX.Y.Z -m "zig-analyzer for VS Code vX.Y.Z"
git push origin editors/vscode/vX.Y.Z
```

## 5. Follow the workflow

```sh
gh run list --workflow vscode-publish.yml --limit 1
gh run watch <run id> --exit-status
```

When it succeeds, the new version appears on the Marketplace after its automatic scan (minutes,
sometimes longer): check `npx --yes @vscode/vsce@4 show jinzhongjia.zig-analyzer` and
https://marketplace.visualstudio.com/items?itemName=jinzhongjia.zig-analyzer. Check Open VSX at
https://open-vsx.org/extension/jinzhongjia/zig-analyzer.

## 6. When something fails

- The tag check fails (lightweight tag, not on `main`, version mismatch): fix the cause, then
  (with the user's consent) delete the tag locally and on `origin` and tag again.
- Checking or packaging fails: fix it on `main` through a pull request, then move the tag (delete
  and push it again, with consent); the version stays the same.
- The Marketplace publish fails with an authentication error: the trusted publishing policy of
  the publisher (https://marketplace.visualstudio.com/manage) must name owner `jinzhongjia`,
  repository `zig-analyzer`, workflow `vscode-publish.yml`, and no environment. Fix it there and
  rerun the failed job (`gh run rerun <run id> --failed`).
- The Open VSX publish fails with an authentication error: the trusted publisher of the
  namespace `jinzhongjia` (https://open-vsx.org, Settings, Trusted Publishers) must name the same
  repository and workflow. Fix it there and rerun the failed job; the Marketplace step skips the
  version it already has.
- After the Marketplace has published a version, never move its tag: release a new patch version
  instead.
