# zig-analyzer 比 ZLS 好在哪

[English](improvements-over-zls.md) | 简体中文

ZLS 是成熟的 Zig 语言服务器。我们在两个真实项目和一个小 fixture 上对比了 ZLS 0.17.0 和 zig-analyzer。下面的数字是 3 轮中位数，Zig 0.17.1，两个服务端都用 ReleaseSafe 构建。项目是 ZLS 自己的源码（37.6k 行，测 `src/analysis.zig`）和 zig-analyzer 的源码（138.8k 行，测 `src/sema/infer.zig`）。

## 诊断

ZLS 的实时诊断只到 AstGen。Sema 错误要靠 build-on-save，而 build-on-save 只有在 `build.zig` 声明 `check` 步骤时才自动启动；否则要用户手动开启，没有 `check` 步骤时只能跑默认步骤或者不构建。

zig-analyzer 通过构建系统协议拿编译器诊断（没有 `build.zig` 的文件走单文件模式），不依赖 `check` 步骤。在一个没有 `check` 步骤的项目里写入 `const n: u32 = "not a number";`，zig-analyzer 在 1.31 s 后报错，ZLS 10 s 内没有任何诊断。有 `check` 步骤时两者都能报，ZLS 更快（383 ms vs 684 ms），但这条路径取决于项目的构建文件。

zig-analyzer 的诊断还有明确的一致性定义：相同内容、Zig 版本、步骤和参数下，文件、位置、severity、消息、notes 和 reference traces 与 `zig build` 逐项相同。ZLS 没有同等定义；它的诊断 source 是 `zls`，编译器诊断走 build-on-save。

类型错误或缺失字段正是用户保存后最需要看到的东西。默认只看 AstGen 是不够的。

## comptime 与泛型

fixture 里 `show(x: anytype)` 被 `Box(u64)` 调用，并读取 `x.value`：

| 查询 | zig-analyzer | ZLS 0.17.0 |
|---|---|---|
| `x.value` 的 hover | `value: u64`，带调用点 | `null` |
| `x.` 后的补全 | `get`、`value` | 只有 `get` |
| `value` 的 goto | `Box` 里的字段声明 | `null` |
| `Box.get` 里 `self.value` 的 hover | `value: u64` | `value: T` |
| `Chosen = if (builtin.os.tag == .linux) u32 else u64` 的 hover | `type = u32` | 同时显示 `u32` 和 `u64` |

ZLS 并非完全没有调用点推断：`identity(x: anytype)` 以 `u32` 调用时，它会显示 `x: anytype` 加 `(type = u32)`。差距在 `anytype` 值的成员访问、泛型容器字段、comptime 分支选择。这些在标准库、allocator、序列化和编译期配置里很常见。

## 重命名与引用

`widget.zig` 声明 `pub fn resize(...)`，`main.zig` 调用 `w.resize(4)`。在声明处请求 references/rename：

| 指标 | zig-analyzer | ZLS |
|---|---|---|
| references（含声明） | 2 | 1 |
| rename 编辑的文件数 | 2 | 1 |
| rename 后 `zig build check` | 通过 | 失败 |

ZLS 的失败信息：

```text
src/main.zig:38:6: error: no field or member function named 'resize' in 'widget.Widget'
    w.resize(4);
    ~^~~~~~~
```

即使 `main.zig` 已经打开、给服务器 5 s 稳定时间，结果也一样。为隔离 rename，测试副本把无关的 `var never_mutated` 改成了 `const`，两个服务端同样处理。ZLS 没找到跨文件方法调用，却仍然返回 rename 编辑，而不是拒绝。

zig-analyzer 在引用无法确认或新名字有歧义时拒绝 rename，并用 AstGen 校验重命名后的文件。rename 静默漏掉调用点，就把重构变成了构建失败。

## 补全与自动导入

zig-analyzer 的补全基于推断和名称解析：作用域内名字、本地值成员（包括 `sema.gpa` 这样的路径）、带 import 编辑的自动导入候选、片段，以及选中时再计算签名和文档的 `completionItem/resolve`。

ZLS 有语义补全和片段，但没有符号级自动导入。它的 completion item 不带 `additionalTextEdits`；运行时测试里，未导入的 `add` 从未出现，zig-analyzer 在后台索引就绪后提供了它，并附上 import 编辑。

成员访问补全召回率：

| 项目 | zig-analyzer | ZLS |
|---|---|---|
| A（ZLS 源码） | 90/90 = 100% | 90/90 = 100% |
| B（zig-analyzer 源码） | 70/70 = 100% | 64/70 = 91.4% |

ZLS 在 B 上的未命中都是需要跨调用/容器类型推断的成员访问。样本不大，但上面的确定性 fixture 是同一方向。

## ZON

zig-analyzer 把 `.zon` 当一等文件类型：任意 `.zon` 文件的解析、格式化和诊断；根表达式大纲；对带结果类型导入的 `.zon` 文件提供类型化补全、goto 和 inlay hints；`build.zig.zon` 的 manifest schema 补全；`zig-analyzer.zon` 的设置补全和选项说明；以及对依赖 URL 运行 `zig fetch` 并写入 hash 的 code action。

ZLS 能格式化 `.zon`，也有基本语法支持，但多处语义功能对 `.zon` 返回 `null`（signature help、inlay hints、references）。测试中，一个有效的 `build.zig.zon` 在 ZLS 里有 0 个文档符号，zig-analyzer 有 5 个（`name`、`version`、`fingerprint`、`minimum_zig_version`、`paths`）。两者的格式化输出都与 `zig fmt` 逐字节一致，所以格式化不是差异点。

`build.zig.zon` 是项目清单。没有 schema 补全、大纲和 hash 辅助，编辑它更慢，也更容易出错。

## 构建系统

zig-analyzer 用 `zig build --listen=-` 拿构建图、编译步骤、模块、生成文件和编译器诊断。它维护编译集合，按编译上下文分析共享文件，按实际缓存解析生成路径，并加载子项目（带自己的 `build.zig`、通过 `.path` 依赖根项目的 examples/benchmarks）。

ZLS 也集成构建系统，但它的构建配置会合并根文件相同的模块；源码注释自己承认这是限制。评测版本里没有等价的子项目加载机制。在同时有 host tool 和交叉编译 target 的项目里，或者带 examples 的库里，同一个文件可能在不同 `builtin`/模块设置下编译；合并这些上下文会给出不完整或错误的导航。

## 性能

暖态中位数，每个单元格 3 轮。项目 A 是 ZLS 的 `src/analysis.zig`，项目 B 是 zig-analyzer 的 `src/sema/infer.zig`。

| 指标 | A：zig-analyzer | A：ZLS | B：zig-analyzer | B：ZLS |
|---|---|---|---|---|
| `initialize` | 0.67 ms | 19.1 ms | 0.83 ms | 48.1 ms |
| hover p50 / p95 | 0.37 / 1.91 ms | 0.58 / 1.31 ms | 0.52 / 3.42 ms | 0.52 / 1.18 ms |
| completion p50 / p95 | 0.44 / 3.85 ms | 0.79 / 4.16 ms | 0.91 / 2.71 ms | 1.88 / 6.89 ms |
| goto p50 / p95 | 0.23 / 0.46 ms | 0.52 / 1.04 ms | 0.37 / 0.54 ms | 0.40 / 0.92 ms |
| 编辑 → 诊断 p50 | 56.2 ms | 6.0 ms | 58.2 ms | 5.4 ms |
| RSS | 127.1 MiB | 60.9 MiB | 127.8 MiB | 66.5 MiB |

项目 A 上固定 250 个请求的 CPU 探针：

| 指标 | zig-analyzer | ZLS |
|---|---|---|
| 墙钟时间 | 244 ms | 341 ms |
| CPU 时间 | 190 ms | 250 ms |
| 每请求 CPU | 0.76 ms | 1.00 ms |

zig-analyzer 不是所有指标都更快。ZLS 在两个项目上的 hover 尾延迟都更好，默认诊断也快得多。zig-analyzer 的优势在初始化握手、goto/completion 的 p50（通常还有 p95）和每请求 CPU。

56–58 ms 的诊断主要是默认 50 ms 防抖。设 `diagnostics.debounce_ms = 0` 后，项目 A 实测约 7 ms，接近 ZLS 的 6 ms。ZLS 没有等价的防抖设置。

## 协议与配置

zig-analyzer 还提供 `completionItem/resolve`、semantic token delta、code action resolve、`zig-analyzer/packages` 检查请求，以及获取依赖 hash 的 `executeCommand`（客户端支持 `workspace/applyEdit` 时）。它约有 44 项设置，嵌套 JSON/ZON，项目设置放 `zig-analyzer.zon`；ZLS 是 22 项扁平设置和 `zls.json`。

看起来像 ZLS 优势的 `willSaveWaitUntil`，其实只是 `force_autofix` 的兜底：默认关闭，只处理手动保存，只应用 `source.fixAll`。zig-analyzer 改为暴露 `source.fixAll` 和 `source.organizeImports`，由编辑器在保存时调用。

## ZLS 更强的地方

- **内存：** A 上 60.9 MiB vs 127.1 MiB，B 上 66.5 MiB vs 127.8 MiB，约为一半。40 行 fixture 上是 14.4 MiB vs 49.0 MiB。
- **二进制：** 完整文件 20.1 MB vs 48.6 MB；stripped 3.5 MB vs 7.7 MB。
- **默认诊断：** 5–6 ms vs 50 ms 防抖下的 56–58 ms。
- **大项目 hover 尾延迟：** B 上 p95 1.18 ms vs 3.42 ms。
- **B 的 semantic tokens：** 32.0 ms vs 38.6 ms。
- **简单与成熟：** 22 项扁平设置 vs 约 44 项嵌套设置；长期部署；学习和运维面更小。
- **Zig master：** ZLS master 面向 Zig 0.18.0-dev；zig-analyzer 0.2.1 面向 Zig 0.17.0/0.17.1。

## 测量方法与限制

每个服务端在每个项目上跑 3 轮。客户端是自建的 stdio LSP 客户端，时延是端到端的，包含 JSON 序列化和客户端解析。暖态测量前有 6 s 稳定期和一轮预热。RSS 是工作负载后的 `VmRSS`，不是峰值。编辑到诊断每轮插入 2–3 次语法错误。

限制也要说清楚：只在 Linux x86-64 上测；两个项目都是语言服务器/编译器基础设施代码，泛型密集；每个指标 30–180 个样本；每轮固定先跑 zig-analyzer、后跑 ZLS，ZLS 的文件缓存可能更暖。ZLS 用的是 0.17.0 tag，不是 0.17.x 最新提交。性能测试关闭了 ZLS build-on-save，而 zig-analyzer 的编译器诊断开着。zig-analyzer 文档里的 15/15 诊断、97 库、10,305 文件语料和 372/372 格式化是项目自报，没有在本机独立复现。

## 怎么选

需要编译器一致诊断、comptime/泛型解析、安全 rename、自动导入、ZON 和构建模型准确性时，选 zig-analyzer。更在意低内存、小二进制、简单成熟的服务器、即时 AstGen 诊断或 Zig master 时，选 ZLS。
