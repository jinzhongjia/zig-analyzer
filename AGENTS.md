# zig-analyzer collaboration conventions

## Git / PR rules (mandatory)

- No commit message may carry LLM co-author information (such as `Co-authored-by: ...` or `Generated with ...`).
- Split the work into multiple commits by the content of the code changes; do not combine unrelated changes in one commit.

## Language

- Everything in the repository is written in English: code, comments, logs, error messages, panic / compileError messages, text sent to the client (progress, showMessage, error responses), tool output, build step descriptions, test names, and documentation (`README.md`, `docs/`).
- Exception: non-ASCII text used deliberately as test data (such as the multi-byte characters that check UTF-8 / UTF-16 position conversion).

## Comments

- Comments describe only the current behavior of the code, its constraints, and the reasons behind them, never stage information: no milestones (M1, v1), no section numbers of the design document (§x.y), and no history or interim results such as "in a later stage / to do later" or "previously / it used to be ..., now it is ...".
- Fix history, interim results, and measurements belong in the commit message or PR description, not in comments. The performance status in `docs/design.md` keeps only the latest data and does not record how it changed over time.
- A regression test case may state in one sentence the wrong behavior it prevents.

## Documentation (`docs/`)

- `docs/design.md`: the main design document. It contains only the design goals, the performance targets and current status, the key design points, and how acceptance is verified. It is updated along with the code and kept consistent with the current implementation; no milestones, development logs, or fix records.
- `docs/plan-*.md`: planning documents, one per piece of work, recording a multi-step plan and its progress. When the work is done, delete its planning document and merge the conclusions that still hold (design decisions, performance data) into `docs/design.md`.
- Records of external issues (such as `docs/neovim-semantic-tokens-race.md`): defects in external implementations such as editor clients and toolchains, one document per issue, describing the symptoms, the cause, the workaround in this project and its cost, how to reproduce it, and the upstream status. Keep them separate from `docs/design.md`; do not merge them into it.

## Goals

- Accuracy is the primary goal: results (diagnostics, goto, references, rename, highlighting, hover, etc.) must be correct and complete; never truncate, approximate, or silently give up for the sake of performance.
- Performance is the secondary goal: optimize only while preserving accuracy, without chasing performance excessively; only remove computation that is proven not to change the results.
- zig-analyzer runs smoothly for code analysis on the Zig source tree.

## Prohibited

Never sacrifice the accuracy of a feature to improve performance!
Do not bother with extreme edge cases that real code never triggers!
