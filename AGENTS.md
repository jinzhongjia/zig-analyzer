# zig-analyzer collaboration conventions

## Git

- No LLM co-author information in commit messages (`Co-authored-by: ...`, `Generated with ...`).
- Split work into commits by content; keep unrelated changes apart.
- Give each pull request one changelog label (`zig build changelog` sorts the release notes by them): `breaking` (users must act on it), `enhancement`, `bug`, `performance`, or `internal` (not visible to users).

## Language

Everything in the repository is in English: code, comments, logs, errors, panic / compileError messages, client-facing text, tool output, build step descriptions, test names, and docs. Exception: non-ASCII text used deliberately as test data.

## Comments

- Describe only current behavior, constraints, and their reasons. No milestones, design-document section numbers, history, or future plans ("later", "previously").
- Fix history, interim results, and measurements belong in the commit message or PR description.
- A regression test may state in one sentence the wrong behavior it prevents.

## Documentation (`docs/`)

- `design.md`: design goals and key design points (layers, query engine, syntax / name / semantic layers, build integration, server, and automated acceptance tests). Updated with the code; no milestones, development logs, or fix records.
- `diagnostics.md`: the definition of diagnostic consistency with the compiler, the file model (origin, compile context, file identity), and the live and compiler diagnostic pipelines.
- `perf.md`: performance targets and current status (latest data only), benchmark tooling, and current acceptance results.
- `features/*.md`: one document per IDE feature (completion, auto-import, navigation, references and rename, code actions, inlay hints, semantic tokens, document structure, formatting).
- `plan-*.md`: one per piece of work, recording a multi-step plan and its progress. When done, delete it and merge lasting conclusions into the matching document.
- External issue records (e.g. `neovim-semantic-tokens-race.md`): one per defect in an editor client, toolchain, etc., covering symptoms, cause, workaround and its cost, reproduction, and upstream status. Keep them separate from `design.md`.

## Goals

- Accuracy first: results (diagnostics, goto, references, rename, highlighting, hover, etc.) must be correct and complete. Never truncate, approximate, or silently give up for performance.
- Performance second: only remove computation proven not to change the results.
- Code analysis runs smoothly on the Zig source tree.
- Do not bother with extreme edge cases that real code never triggers.
