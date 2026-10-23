# zig-analyzer 协作约定

## Git / PR 规则（必须遵守）

- commit 的 author email 必须使用 `mail@nvimer.org`。
- 任何 commit message 都不允许携带 LLM co-author 信息（如 `Co-authored-by: ...`、`Generated with ...`）。
- 按代码修改内容拆分为多个 commit 提交，不要把无关改动合并到一个 commit。
- 有 PR 时，需要监听 CI 状态，确保所有 CI 执行都通过。
- 用户要求处理 PR 的 comment 时，使用 loop 持续监听 PR 的 comment，直到所有 comment 处理完成。

## 代码语言

- 只有注释使用中文。
- 日志、错误消息、panic / compileError、发给客户端的文案（进度、showMessage、错误响应）、工具输出、build step 描述、测试名一律使用英文。

## 注释

- 注释只描述代码当前的行为、约束与原因，不写阶段性信息：不出现里程碑（M1、v1）、设计文档的章节号（§x.y）、「后续阶段 / 以后再做」、「此前 / 原来是…，现在改为…」之类的演进过程与阶段成果。
- 修复历史、阶段成果、测量数据写在 commit message 或 PR 描述里，不写进注释。`docs/design.md` 的性能现状只保留最新数据，不记录历次变化。
- 测试中的回归用例可以用一句话说明它防止的错误行为。

## 文档（`docs/`）

- `docs/design.md`：主要设计文档，只保留设计目标、性能目标与现状、设计要点、验收方式。内容随代码更新，保持与当前实现一致；不写里程碑、开发日志与修复记录。
- `docs/plan-*.md`：规划文档，一项工作一份，记录多步计划与进度。工作完成后删除对应的规划文档，其中仍然有效的结论（设计决策、性能数据）合并进 `docs/design.md`。
- 外部问题的记录（如 `docs/neovim-semantic-tokens-race.md`）：编辑器客户端、工具链等外部实现的缺陷，一个问题一份，写现象、原因、本项目的规避与代价、复现方法与上游状态；与 `docs/design.md` 分开，不合并进去。

## 目标

- 在 zig 源代码库可以流畅使用 zig-analyzer 进行代码分析。

## 禁止

禁止为了提升性能而牺牲功能的准确性！
编程不会触发的极端边界 case 不用考虑！
