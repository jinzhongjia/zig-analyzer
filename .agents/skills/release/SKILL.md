---
name: release
description: Release a new version of the zig-analyzer server (version bump, CHANGELOG.md section, annotated tag, GitHub release built, smoke-tested, signed, and attested by .github/workflows/release.yml). Use when asked to release, cut, tag, or publish a version or a release candidate of zig-analyzer.
---

# Release zig-analyzer

A release is an annotated tag `vX.Y.Z` (or `vX.Y.Z-rc.N` for a release candidate) on `main`.
Pushing it runs `.github/workflows/release.yml`:

1. **check**: the tag is annotated, on `main`, matches `.version` in `build.zig.zon`, and
   `CHANGELOG.md` has a section for the version; the signing key is set up.
2. **ci**: the whole CI (`ci.yml`) on the tagged commit.
3. **build**: ReleaseSafe and ReleaseFast executables cross-compiled for x86_64 / aarch64 ×
   Linux / macOS / Windows (12 archives).
4. **smoke**: each archive unpacked on a runner of its platform and checked over LSP
   (`tools/release_smoke.zig`: handshake, `serverInfo.version`, hover in `editors/test-project`,
   clean shutdown).
5. **release**: `SHA256SUMS`, a minisign signature (`.minisig`) for every file, verified against
   `minisign.pub`, build provenance attestations, and the GitHub release, with the version's section
   of `CHANGELOG.md` as the notes. A version with a `-` is published as a pre-release.

The signing key is in the secrets `MINISIGN_SECRET_KEY` and `MINISIGN_PASSWORD` of the `release`
environment, which only `v*` tags can deploy to. Only repository admins can create, move, or delete
`v*` tags (ruleset "Release tags"), and published releases are immutable. The editor extensions in
`editors/` are versioned and published separately; a release does not touch them.

Ask the user before each step that is visible to others: pushing to `main`, pushing the tag, and
deleting a tag or release.

## 1. Preconditions

```sh
git switch main && git pull --ff-only
git status --short                                  # clean, apart from untracked local files
gh auth status
git describe --tags --abbrev=0 --match 'v[0-9]*'    # the last release; none before the first
```

## 2. Choose the version

Semantic versioning, independent of the Zig version. Read the changes since the last release:

```sh
git log --first-parent --oneline <last tag>..main
```

While the major version is 0: a minor bump for changes users must act on (options removed or
renamed, a different Zig version required, changed behavior of custom requests) or for notable new
features, a patch bump otherwise. A release candidate (`X.Y.Z-rc.N`) lets users try a minor
release first; the final `X.Y.Z` follows when no fix is needed. Propose the version with the reason
and let the user decide.

Check the tag does not exist yet: `git tag -l vX.Y.Z` and `git ls-remote --tags origin vX.Y.Z`.

## 3. Check CI

The CI run of `main` should have passed; the release workflow runs it again on the tagged commit
and refuses to publish otherwise, but a failure found now saves the tag:

```sh
gh run list --workflow ci.yml --branch main --commit "$(git rev-parse main)"
```

Stop on a failure and report it.

## 4. Write the changelog

Label the pull requests merged since the last release that have none of the changelog labels:
`breaking` (users must act on it), `enhancement` (a feature), `bug` (a fix), `performance`, or
`internal` (not visible to users: refactoring, tests, CI, docs for developers). Show the user the
proposed labels before setting them (`gh pr edit <n> --add-label <label>`).

Then generate the section:

```sh
tools/changelog.sh X.Y.Z
```

It adds `## [X.Y.Z](<release URL>) - <date>` to `CHANGELOG.md`, one line per pull request under
"Breaking changes", "Features", "Fixes", "Performance", and "Other changes". Edit the lines into
user-facing text: what changed for the user, in one line each, keeping the PR links; merge lines
about the same change; add a first line when the Zig versions supported change. Show the section to
the user and revise it until approved.

## 5. Bump the version

`.version` in `build.zig.zon` is the single source of the version; the tag only marks its commit.
Set it to `X.Y.Z` (no `v`). Until the tag exists, builds print `X.Y.Z-dev+<commit>`; at the tagged
commit `X.Y.Z`; after it `X.Y.Z+<commits since the tag>.g<commit>`. Commit it with the changelog on
`main`:

```
release: vX.Y.Z
```

## 6. Tag and push

The tag message is `zig-analyzer vX.Y.Z`; the notes come from `CHANGELOG.md`.

```sh
git tag -a vX.Y.Z -m "zig-analyzer vX.Y.Z"
git push origin main
git push origin vX.Y.Z
```

## 7. Follow the workflow

```sh
gh run list --workflow release.yml --limit 1
gh run watch <run id> --exit-status
```

The CI part takes about an hour. If no run starts within a few minutes, tell the user; the tag is
pushed but there is no release yet. Do not build and upload the release by hand unless the user
asks.

When it succeeds, check the release:

```sh
gh release view vX.Y.Z    # 12 archives (.tar.gz, .zip for Windows), SHA256SUMS, and a .minisig for each
gh release download vX.Y.Z -p '*-<this machine>-ReleaseSafe.tar.gz*' -p 'SHA256SUMS*' -D <empty temporary dir>
```

In that directory, verify the signatures against `minisign.pub` (`minisign -Vm <file> -p minisign.pub`
for the archive and `SHA256SUMS`), the provenance (`gh attestation verify <archive> --repo
jinzhongjia/zig-analyzer`), and the checksum (`shasum -a 256 -c SHA256SUMS --ignore-missing`), then
extract and check that `zig-analyzer --version` prints `X.Y.Z`.

## 8. When something fails

Until the release is published nothing is public but the tag, and a tag can be deleted only by an
admin (the ruleset lets the user, not the workflow, do it).

- `check` fails: the tag is not annotated, not on `main`, or does not match `build.zig.zon` or
  `CHANGELOG.md`; or the `release` environment lacks the signing key. Fix the cause, then (with
  the user's consent) delete the tag locally and on `origin` and tag again.
- `ci`, `build`, or `smoke` fails: fix it on `main` through the usual PR, then move the tag to the
  fixed commit (delete and push it again, with consent); the version stays the same.
- `release` fails before publishing (signing, attestation): fix the workflow on `main` the same way.
  A draft release left behind is deleted (with consent) before the tag is pushed again.
- After the release is published, never move or reuse its tag: release a new patch version instead.
