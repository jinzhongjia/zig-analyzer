# zig-analyzer 与 ZLS 对比

[English](improvements-over-zls.md) | 简体中文

版本：ZLS 0.17.0（[`542462c`][zls]）和 zig-analyzer 0.2.1，都用 ReleaseSafe 构建，Zig 0.17.1。测量用了两个项目和一个小 fixture：项目 A 是 ZLS 源码（37.6k 行，在 `src/analysis.zig` 上测），项目 B 是 zig-analyzer 源码（138.8k 行，在 `src/sema/infer.zig` 上测）。数字取 3 轮中位数。关于 ZLS 行为的说法都链接到该提交的源码。

[zls]: https://github.com/zigtools/zls/tree/542462c4ddf045493fa9ca028ee6bc3f38b2754a

## 诊断

ZLS 的实时诊断只跑 AstGen（[`diagnostics.zig:30-58`][zls-diag]），Sema 错误来自 build-on-save。Zig 支持文件监听时 build-on-save 默认开启（[`Server.zig:781`][zls-bos]），但没有显式设置 `enable_build_on_save` 时只跑 `check` 步骤；`build.zig` 里没有 `check` 就不构建（[`bsp.zig:1088-1094`][zls-check]）。

zig-analyzer 通过 `zig build --listen=-` 拿编译器诊断（构建之外的文件走单文件模式），有没有 `check` 步骤都一样。发布的诊断在相同内容、Zig 版本、步骤和参数下与 `zig build` 一致：文件、位置、severity、消息、notes 和 reference traces（[`diagnostics.md`](diagnostics.md)）。

在项目里写入 `const n: u32 = "not a number";`：

| | zig-analyzer | ZLS |
|---|---|---|
| 没有 `check` 步骤 | 1.31 s 后报错 | 10 s 内无诊断 |
| 有 `check` 步骤 | 684 ms | 383 ms |

[zls-diag]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/diagnostics.zig#L30-L58
[zls-bos]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/Server.zig#L780-L784
[zls-check]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/bsp.zig#L1088-L1094

## comptime 与泛型

fixture：`show(x: anytype)` 以 `Box(u64)` 调用，读取 `x.value`。

| 查询 | zig-analyzer | ZLS |
|---|---|---|
| `x.value` 的 hover | `value: u64`，带调用点 | `null` |
| `x.` 后的补全 | `get`、`value` | `get` |
| `value` 的 goto | `Box` 里的字段声明 | `null` |
| `Box.get` 里 `self.value` 的 hover | `value: u64` | `value: T` |
| `Chosen = if (builtin.os.tag == .linux) u32 else u64` 的 hover | `type = u32` | `u32` 和 `u64` 都显示 |

ZLS 有部分调用点推断：`identity(x: anytype)` 以 `u32` 调用时显示 `x: anytype` 和 `(type = u32)`。它处理不了 `anytype` 值的成员访问、泛型容器的字段和 comptime 分支选择。

## 重命名与引用

`widget.zig` 声明 `pub fn resize(...)`，`main.zig` 调用 `w.resize(4)`。在声明处请求 references 和 rename：

| | zig-analyzer | ZLS |
|---|---|---|
| references（含声明） | 2 | 1 |
| rename 修改的文件数 | 2 | 1 |
| rename 后 `zig build check` | 通过 | 失败 |

```text
src/main.zig:38:6: error: no field or member function named 'resize' in 'widget.Widget'
    w.resize(4);
    ~^~~~~~~
```

`main.zig` 已打开并等待 5 s 后结果相同。测试副本把无关的 `var never_mutated` 改成了 `const`，保证构建只会因 rename 失败；两个服务端用的是同一份副本。

zig-analyzer 在引用无法确认或新名字冲突时拒绝 rename，并用 AstGen 检查改名后的文件（[`features/references-rename.md`](features/references-rename.md)）。

## 补全与自动导入

ZLS 的补全项不带 `additionalTextEdits`（它的 `src/` 里没有这个字段名），因此无法插入 import。运行时测试里，ZLS 始终没有给出未导入的 `add`；zig-analyzer 在后台索引就绪后给出了它，并附带 import 编辑（[`features/auto-import.md`](features/auto-import.md)）。

成员访问补全召回率：

| 项目 | zig-analyzer | ZLS |
|---|---|---|
| A | 90/90（100%） | 90/90（100%） |
| B | 70/70（100%） | 64/70（91.4%） |

ZLS 在 B 上漏掉的 6 处都需要跨调用或经过容器的类型推断。

## ZON

ZLS 对 `.zon` 文件的 hover、goto、补全、references、signature help、inlay hints、文档符号和 code action 都返回 `null`（[`hover.zig:506`][zon-hover]、[`goto.zig:292`][zon-goto]、[`completions.zig:1042`][zon-comp]、[`references.zig:741`][zon-refs]、[`signature_help.zig:29`][zon-sig]、[`inlay_hints.zig:163`][zon-inlay]、[`document_symbol.zig:26`][zon-sym]、[`code_actions.zig:39`][zon-ca]）。它能格式化 `.zon`，也提供 semantic tokens。

zig-analyzer 对 `.zon` 提供：任意文件的诊断、格式化和大纲；带结果类型导入的文件的类型化补全、goto 和 inlay hints；`build.zig.zon` 和 `zig-analyzer.zon` 的 schema 补全；对依赖 URL 运行 `zig fetch` 并写入 hash 的 code action。一个有效的 `build.zig.zon` 有 5 个文档符号（`name`、`version`、`fingerprint`、`minimum_zig_version`、`paths`）。

两者的格式化输出在测试用的 `.zig` 和 `.zon` 文件上都与 `zig fmt` 逐字节一致。

[zon-hover]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/hover.zig#L506
[zon-goto]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/goto.zig#L292
[zon-comp]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/completions.zig#L1042
[zon-refs]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/references.zig#L741
[zon-sig]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/signature_help.zig#L29
[zon-inlay]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/inlay_hints.zig#L163
[zon-sym]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/document_symbol.zig#L26
[zon-ca]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/features/code_actions.zig#L39

## 构建系统

ZLS 会合并根文件相同的模块，源码注释写着："All modules with the same root source file are merged. This limitation may be lifted in the future."（[`bsp.zig:25`][zls-merge]）。一个文件同时被 host 工具和交叉编译目标编译，或者在不同模块里有不同 import 时，只按合并后的一个上下文分析。

zig-analyzer 分开保留每个编译，按编译分析共享文件，按实际缓存解析生成文件，并按需加载子项目（有自己的 `build.zig`、通过 `.path` 依赖根项目的目录，比如 examples）（[`design.md`](design.md#sub-projects)）。ZLS 0.17.0 没有对应的子项目加载。

[zls-merge]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/bsp.zig#L25

## 性能

暖态，每格 3 轮中位数：

| | A：zig-analyzer | A：ZLS | B：zig-analyzer | B：ZLS |
|---|---|---|---|---|
| `initialize` | 0.67 ms | 19.1 ms | 0.83 ms | 48.1 ms |
| hover p50 / p95 | 0.37 / 1.91 ms | 0.58 / 1.31 ms | 0.52 / 3.42 ms | 0.52 / 1.18 ms |
| completion p50 / p95 | 0.44 / 3.85 ms | 0.79 / 4.16 ms | 0.91 / 2.71 ms | 1.88 / 6.89 ms |
| goto p50 / p95 | 0.23 / 0.46 ms | 0.52 / 1.04 ms | 0.37 / 0.54 ms | 0.40 / 0.92 ms |
| 编辑 → 诊断 p50 | 56.2 ms | 6.0 ms | 58.2 ms | 5.4 ms |
| semantic tokens | | | 38.6 ms | 32.0 ms |
| RSS | 127.1 MiB | 60.9 MiB | 127.8 MiB | 66.5 MiB |

A 上固定 250 个请求：

| | zig-analyzer | ZLS |
|---|---|---|
| 墙钟时间 | 244 ms | 341 ms |
| CPU 时间 | 190 ms | 250 ms |
| 每请求 CPU | 0.76 ms | 1.00 ms |

zig-analyzer 的编辑 → 诊断时间主要是默认 50 ms 防抖（`diagnostics.debounce_ms`），设为 0 后 A 上约 7 ms。ZLS 没有防抖。

## 协议与配置

zig-analyzer 还实现了 `completionItem/resolve`、semantic token delta、`codeAction/resolve`、`zig-analyzer/packages` 请求，以及获取依赖 hash 的 `executeCommand`。它有 44 项分节设置，来自编辑器设置或 `zig-analyzer.zon`（[`src/server/Config.zig`](../src/server/Config.zig)）。ZLS 有 22 项扁平设置，放在 `zls.json`（[`Config.zig`][zls-config]）。

ZLS 声明了 `willSaveWaitUntil`，但只在开启 `force_autofix`（默认关闭）时使用，只处理手动保存，只应用 AstGen 修复（[`Server.zig:268-283`][zls-autofix]、[`Server.zig:1210-1219`][zls-wswu]）。zig-analyzer 提供 `source.fixAll` 和 `source.organizeImports` code action，由编辑器在保存时调用。

[zls-config]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/Config.zig
[zls-autofix]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/Server.zig#L268-L283
[zls-wswu]: https://github.com/zigtools/zls/blob/542462c4ddf045493fa9ca028ee6bc3f38b2754a/src/Server.zig#L1210-L1219

## ZLS 更好的地方

- 内存：约一半（A 上 60.9 vs 127.1 MiB，B 上 66.5 vs 127.8 MiB，40 行 fixture 上 14.4 vs 49.0 MiB）。
- 二进制大小：20.1 vs 48.6 MB，strip 后 3.5 vs 7.7 MB。
- 实时 AstGen 诊断：5-6 ms，zig-analyzer 默认防抖下 56-58 ms。
- hover p95：A 上 1.31 vs 1.91 ms，B 上 1.18 vs 3.42 ms。
- B 上的 semantic tokens：32.0 vs 38.6 ms。
- 设置更少（22 vs 44），部署历史更长。
- Zig master：ZLS master 要求 Zig 0.18.0-dev（[`build.zig.zon`](https://github.com/zigtools/zls/blob/master/build.zig.zon)）；zig-analyzer 0.2.1 支持 Zig 0.17.x。

## 测量方法

用专门的 LSP 客户端通过 stdio 驱动服务端；时延是端到端的，包含 JSON 编解码。暖态测量在 6 s 稳定期和一轮预热之后开始。RSS 是负载结束后的 `VmRSS`，不是峰值。编辑 → 诊断每轮插入 2-3 个语法错误。每个指标 30-180 个样本。

局限：

- 只在 Linux x86-64 上测。
- 两个项目都是编译器/语言服务器代码，泛型用得多。
- 每轮都先跑 zig-analyzer，ZLS 的文件缓存可能更暖。
- 性能测试中 ZLS 的 build-on-save 关闭，zig-analyzer 的编译器诊断开启。
