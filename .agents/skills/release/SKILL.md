---
name: release
description: Release a new version of the zig-analyzer server (version bump, CHANGELOG.md section, annotated tag, GitHub release built, smoke-tested, signed, and attested by .github/workflows/release.yml). Use when asked to release, cut, tag, or publish a version or a release candidate of zig-analyzer.
---

# Release zig-analyzer

A release is an annotated tag `vX.Y.Z` (or `vX.Y.Z-rc.N` for a release candidate) on `main`.
Pushing it runs `.github/workflows/release.yml`:

1. **check**: the tag is annotated, on `main`, matches `.version` in `build.zig.zon`, and
   `CHANGELOG.md` has a section for the version; the signing key is set up.
2. **ci**: the whole CI (`ci.yml`) on the tagged commit. Skipped when the tagged commit has one
   parent, changes only `CHANGELOG.md` and the `.version` line of `build.zig.zon`, and the push of
   the parent to `main` passed CI (`check` says which in the log of its last step): that run
   stands for the tagged commit.
3. **build**: ReleaseSafe and ReleaseFast executables cross-compiled for x86_64 / aarch64 ×
   Linux / macOS / Windows (12 archives).
4. **smoke**: each archive unpacked on a runner of its platform and checked over LSP
   (`tools/release_smoke.zig`: handshake, `serverInfo.version`, hover in `editors/test-project`,
   clean shutdown).
5. **release**: `SHA256SUMS`, a minisign signature (`.minisig`) for every file, verified against
   `minisign.pub`, build provenance attestations, and the GitHub release, with the version's section
   of `CHANGELOG.md` as the notes. A version with a `-` is published as a pre-release.
6. **homebrew** (not for pre-releases): the formula that `zig build homebrew-formula`
   (`tools/homebrew_formula.zig`) writes from the release's `SHA256SUMS` is committed to the tap
   `jinzhongjia/homebrew-tap`, whose CI then audits, installs, and tests it on macOS and Linux.
7. **aur** (not for pre-releases): the `PKGBUILD` and `.SRCINFO` of `zig-analyzer-bin` that
   `zig build aur-pkgbuild` (`tools/aur_pkgbuild.zig`) writes from the release's `SHA256SUMS` are
   built, checked with namcap, installed, and run in an `archlinux` container, then pushed to
   `ssh://aur@aur.archlinux.org/zig-analyzer-bin.git`.

The signing key is in the secrets `MINISIGN_SECRET_KEY` and `MINISIGN_PASSWORD` of the `release`
environment, which only `v*` tags can deploy to; `HOMEBREW_TAP_DEPLOY_KEY` there is a deploy key of
the tap with write access, and `AUR_SSH_PRIVATE_KEY` the SSH key of the AUR account that maintains
`zig-analyzer-bin`. Only repository admins can create, move, or delete
`v*` tags (ruleset "Release tags"), and published releases are immutable. The editor extensions in
`editors/` are versioned and published separately; a release does not touch them (the VS Code
extension: the release-vscode skill).

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

The CI run of `main` must have passed and completed: the release commit (step 6) then changes
only the changelog and the version, and the release workflow uses that run instead of running CI
again. Without it (still running, cancelled, or failed), the workflow runs the whole CI on the
tagged commit, which takes about an hour, and refuses to publish if it fails:

```sh
gh run list --workflow ci.yml --branch main --commit "$(git rev-parse main)"
```

Stop on a failure and report it; wait for a run in progress. Put nothing but the changelog and
the version in the release commit.

## 4. Write the changelog

Label the pull requests merged since the last release that have none of the changelog labels:
`breaking` (users must act on it), `enhancement` (a feature), `bug` (a fix), `performance`, or
`internal` (not visible to users: refactoring, tests, CI, docs for developers). Show the user the
proposed labels before setting them (`gh pr edit <n> --add-label <label>`).

Then generate the section:

```sh
zig build changelog -- X.Y.Z
```

It adds `## [X.Y.Z](<release URL>) - <date>` to `CHANGELOG.md`, one line per pull request under
"Breaking changes", "Features", "Fixes", "Performance", and "Other changes". Edit the lines into
user-facing text: what changed for the user, in one line each, keeping the PR links; merge lines
about the same change; add a first line when the Zig versions supported change. Show the section to
the user and revise it until approved.

## 5. Compare performance with the last release

The changelog section ends with a `### Performance compared with vA.B.C` subsection, where `vA.B.C`
is the release the section counts from (for a candidate, the last final release). Measure on this
machine with the current benchmark client against both servers; it takes about 10 minutes. Measure
`main` as it will be tagged, after step 3.

Build both servers and the benchmark client in a temporary directory outside the repository:

```sh
B=$(mktemp -d)
git worktree add --detach "$B/old" vA.B.C
git worktree add --detach "$B/new" main
(cd "$B/old" && zig build -Doptimize=ReleaseSafe) & (cd "$B/new" && zig build -Doptimize=ReleaseSafe) & wait
(cd "$B/new" && zig build bench -Doptimize=ReleaseSafe)   # builds lsp-bench; the run fails without arguments
cp "$(ls -t $(find "$B/new/.zig-cache/o" -name lsp-bench -type f) | head -1)" "$B/lsp-bench"
```

The benchmark project is the Zig compiler source of the local `zig version`: the `src.tarball` of
that version in https://ziglang.org/download/index.json, checked against its `src.shasum` and
extracted into its own empty directory `$B/src`. The tarball has no `.git`, so its `build.zig`
needs `-Dversion-string`:

```sh
v=$(zig version)
P=$B/src/zig-$v
export BENCH_CONFIG='{"completion":{"snippets":false},"build":{"args":["-Dversion-string='"$v"'"]}}'
run() { "$B/lsp-bench" "$B/$1/zig-out/bin/zig-analyzer" "$P" "$3" > "$B/$2-$1.txt" 2>&1; echo "exit $?" >> "$B/$2-$1.txt"; }
run old warm src/Sema.zig; run new warm src/Sema.zig   # warms the zig build cache; discarded
for r in 1 2 3; do run old full$r src/Sema.zig; run new full$r src/Sema.zig; done
export BENCH_QUICK=1 BENCH_REFS=40
for r in 1 2; do for f in Sema Zcu; do run old refs-$f$r src/$f.zig; run new refs-$f$r src/$f.zig; done; done
```

Every output must end with `checks failed: 0` and `exit 0`, and none may contain `failed to
configure`; otherwise fix the setup and measure again. When the release's Performance lines claim
a gain these runs do not exercise, add the matching runs from the header of `tools/lsp_bench.zig`
(`BENCH_SAVE=1` for compiler diagnostics, `BENCH_TYPE_WORDS` for typing, `BENCH_CONCURRENT`,
`BENCH_INSTANCE_HOVER`, ...) with two rounds per version, alternating as above.

Write the subsection from the results:

- One line with the setup: OS and architecture, CPU count, ReleaseSafe, the Zig version, the
  measured files, and the number of rounds.
- A table `| Scenario | vA.B.C | vX.Y.Z | Change |` of the metrics whose ranges over the rounds do not
  overlap between the versions, improvements and regressions alike, giving each version's range
  (`7.1–10.0 ms`) and the change as a factor or percentage. Slowest requests (`max`) count only when
  every round agrees.
- Resident memory at the end of the full run, always.
- One line naming the metrics that are unchanged within noise.

No rows of wins the runs did not show; the per-PR numbers stay in the Performance lines above it.
Show the subsection to the user and revise it until approved, as with the rest of the section. Remove the worktrees and the
directory afterwards (`git worktree remove --force "$B/old"`, the same for `"$B/new"`, then
`rm -rf "$B"`).

For a final release after candidates, `zig build changelog` replaces the candidates' sections, so
measure again against the last final release.

## 6. Bump the version

`.version` in `build.zig.zon` is the single source of the version; the tag only marks its commit.
Set it to `X.Y.Z` (no `v`). Until the tag exists, builds print `X.Y.Z-dev+<commit>`; at the tagged
commit `X.Y.Z`; after it `X.Y.Z+<commits since the tag>.g<commit>`. Commit it with the changelog on
`main`:

```
release: vX.Y.Z
```

## 7. Tag and push

The tag message is `zig-analyzer vX.Y.Z`; the notes come from `CHANGELOG.md`.

```sh
git tag -a vX.Y.Z -m "zig-analyzer vX.Y.Z"
git push origin main
git push origin vX.Y.Z
```

## 8. Follow the workflow

```sh
gh run list --workflow release.yml --limit 1
gh run watch <run id> --exit-status
```

Building, the smoke tests, and publishing take about 20 minutes; when CI runs too (see step 2 of
the workflow above), about an hour. If no run starts within a few minutes, tell the user; the tag is
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

For a final release, check that the tap has the commit `zig-analyzer X.Y.Z` and that its CI passed
(`gh run list -R jinzhongjia/homebrew-tap --limit 1`), and that
https://aur.archlinux.org/packages/zig-analyzer-bin shows `X.Y.Z-1`. The Scoop manifest `bucket/zig-analyzer.json`
of `jinzhongjia/scoop-bucket` is not updated by this workflow: the bucket's Excavator workflow
picks up the latest release within four hours (its `checkver` and `autoupdate`, hashes from
`SHA256SUMS`).

## Pre-releases

A release candidate `vX.Y.Z-rc.N` goes through the same steps with the version `X.Y.Z-rc.N`
everywhere (`build.zig.zon`, `zig build changelog -- X.Y.Z-rc.N`, the tag). The workflow publishes it
as a pre-release, so it does not become the latest release.

- Its changelog section counts from the last final release, not from the previous candidate, so
  each candidate lists everything users get compared with the last final release.
- Fixes found in a candidate are merged to `main` as usual and released as the next candidate
  (`rc.N+1`); a published candidate is never moved.
- The final `X.Y.Z` is a new release commit: `zig build changelog -- X.Y.Z` replaces the sections of
  its candidates with one section since the last final release, and `build.zig.zon` drops the
  suffix. The candidates' GitHub releases stay as they are.

## 9. When something fails

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
- `homebrew` fails: the release is published; fix the cause (the deploy key, or the tool on
  `main`) and rerun the job (`gh run rerun <run id> --failed`). It runs the tool of the tagged
  commit, so a fixed tool applies from the next release; until then, generate the formula with
  the fixed tool and commit it to the tap by hand (with consent).
- `aur` fails: the release is published; the same applies, with the AUR package in place of the
  formula. To change the package within a version (a fix of `PKGBUILD` only), raise `pkgrel` in
  both files and push by hand (with consent).
