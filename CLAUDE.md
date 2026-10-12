# zig-analyzer 协作约定

## Git / PR 规则（必须遵守）

- commit 的 author email 必须使用 `mail@nvimer.org`。
- 任何 commit message 都不允许携带 LLM co-author 信息（如 `Co-authored-by: ...`、`Generated with ...`）。
- 按代码修改内容拆分为多个 commit 提交，不要把无关改动合并到一个 commit。
- 有 PR 时，需要监听 CI 状态，确保所有 CI 执行都通过。
- 用户要求处理 PR 的 comment 时，使用 loop 持续监听 PR 的 comment，直到所有 comment 处理完成。
