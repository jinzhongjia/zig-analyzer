---
name: release
description: Release a new version of the zig-analyzer server (version bump, local verification, release notes, annotated tag, GitHub release built by .github/workflows/release.yml). Use when asked to release, cut, tag, or publish a version of zig-analyzer.
---

# Release zig-analyzer

A release is an annotated tag `vX.Y.Z` on `main`. Pushing it runs `.github/workflows/release.yml`,
which checks the tag, cross-compiles ReleaseSafe and ReleaseFast executables for x86_64 / aarch64 ×
Linux / macOS / Windows, signs the archives and `SHA256SUMS` with minizign, and publishes a GitHub
release with them, their `.minisig` signatures, and the tag message as the notes. Signing needs the
repository secrets `MINISIGN_SECRET_KEY` (the secret key file) and `MINISIGN_PASSWORD`, matching
`minisign.pub`. The editor extensions in `editors/` are versioned and published separately; a
release does not touch them.

Ask the user before each step that is visible to others: pushing to `main`, pushing the tag, and
deleting a tag or release.

## 1. Preconditions

```sh
git switch main && git pull --ff-only
git status --short                    # clean, apart from untracked local files
gh auth status
git describe --tags --abbrev=0        # the last release; none before the first
```

## 2. Choose the version

Semantic versioning, independent of the Zig version. Without a previous release, the first is
`v0.1.0`. Read the changes since the last release:

```sh
git log --first-parent --oneline <last tag>..main
```

While the major version is 0: a minor bump for changes users must act on (options removed or
renamed, a different Zig version required, changed behavior of custom requests) or for notable new
features, a patch bump otherwise. Propose the version with the reason and let the user decide.

Check the tag does not exist yet: `git tag -l vX.Y.Z` and `git ls-remote --tags origin vX.Y.Z`.

## 3. Verify

The CI run of the commit to release must have passed on every platform:

```sh
gh run list --workflow ci.yml --branch main --commit "$(git rev-parse main)"
```

Stop on any failure and report it; a release is never cut over failing tests. The version bump
in the next step changes only `build.zig.zon`, so it needs no new run.

## 4. Bump the version

`.version` in `build.zig.zon` is the single source of the version; the tag only marks its commit.
Set it to `X.Y.Z` (no `v`). The workflow refuses a tag that does not match it. Until the tag
exists, builds print `X.Y.Z-dev+<commit>`; at the tagged commit `X.Y.Z`; after it
`X.Y.Z+<commits since the tag>.g<commit>`. Commit it alone on `main`:

```
release: vX.Y.Z
```

## 5. Write the release notes

In English, Markdown, from the commits and merged PRs since the last release (the PR titles and
descriptions are the best source: `gh pr list --state merged --base main --search "merged:>=<date of the last tag>"`).
Write for users, not for developers of the analyzer:

```markdown
Supports Zig 0.17.0 and 0.17.1.

## Breaking changes
- ...

## Features
- ...

## Fixes
- ...

## Performance
- ...
```

Leave out empty sections and changes users cannot observe (refactoring, tests, CI). Each item says
what changed for the user in one line, with the PR number (`(#123)`). Show the notes to the user and
revise them until approved.

## 6. Tag and push

The tag message is `zig-analyzer vX.Y.Z`, a blank line, then the notes; the workflow publishes the
part after the blank line. `--cleanup=whitespace` keeps the `#` of Markdown headings, which the
default cleanup would strip as comments.

```sh
git tag -a vX.Y.Z --cleanup=whitespace -F <message file>
git tag -l --format='%(contents:body)' vX.Y.Z    # check the notes survived intact
git push origin main
git push origin vX.Y.Z
```

## 7. Follow the workflow

```sh
gh run list --workflow release.yml --limit 1
gh run watch <run id> --exit-status
```

If no run starts within a few minutes, tell the user; the tag is pushed
but there is no release yet. Do not build and upload the release by hand unless the user asks.

When it succeeds, check the release:

```sh
gh release view vX.Y.Z    # 12 archives (.tar.gz, .zip for Windows), SHA256SUMS, and a .minisig for each
gh release download vX.Y.Z -p '*-<this machine>-ReleaseSafe.tar.gz*' -p 'SHA256SUMS*' -D <empty temporary dir>
```

In that directory, verify the signatures against `minisign.pub` (`minisign -Vm <file> -p minisign.pub`
for the archive and `SHA256SUMS`), the checksum (`shasum -a 256 -c SHA256SUMS --ignore-missing`),
extract, and check that `zig-analyzer --version` prints `X.Y.Z`.

## 8. When something fails

- The `check` job fails: the tag is not annotated, not on `main`, or does not match
  `build.zig.zon`. Fix the cause, then (with the user's consent) delete the tag locally and on
  `origin` and tag again; nothing was published.
- A build fails: fix it on `main` through the usual PR. Since the version is not released, the tag
  may be moved to the fixed commit (delete and push it again, with consent); the version in `build.zig.zon` stays the same.
- After the release is published, never move or reuse its tag: release a new patch version instead.
