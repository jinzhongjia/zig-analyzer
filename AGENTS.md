# zig-analyzer collaboration conventions

## Git

- No LLM co-author information in commit messages (`Co-authored-by: ...`, `Generated with ...`).
- Split work into commits by content; keep unrelated changes apart.

## Language

Everything in the repository is in English: code, comments, logs, errors, panic / compileError messages, client-facing text, tool output, build step descriptions, test names, and docs. Exception: non-ASCII text used deliberately as test data.

## Comments

- Describe only current behavior, constraints, and their reasons. No milestones, design-document section numbers, history, or future plans ("later", "previously").
- Fix history, interim results, and measurements belong in the commit message or PR description.
- A regression test may state in one sentence the wrong behavior it prevents.

## Documentation (`docs/`)

- `design.md`: design goals, performance targets and current status (latest data only), key design points, and acceptance verification. Updated with the code; no milestones, development logs, or fix records.
- `plan-*.md`: one per piece of work, recording a multi-step plan and its progress. When done, delete it and merge lasting conclusions into `design.md`.
- External issue records (e.g. `neovim-semantic-tokens-race.md`): one per defect in an editor client, toolchain, etc., covering symptoms, cause, workaround and its cost, reproduction, and upstream status. Keep them separate from `design.md`.

## Goals

- Accuracy first: results (diagnostics, goto, references, rename, highlighting, hover, etc.) must be correct and complete. Never truncate, approximate, or silently give up for performance.
- Performance second: only remove computation proven not to change the results.
- Code analysis runs smoothly on the Zig source tree.
- Do not bother with extreme edge cases that real code never triggers.
