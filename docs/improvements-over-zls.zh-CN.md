# zig-analyzer 相比 ZLS 的改进

[English](improvements-over-zls.md) | 简体中文

**技术文档 · v1.0 · 2026-11-18**

**对象：** zig-analyzer `0.2.1+20.g7108016` 与 ZLS `0.17.0`  
**范围：** 语言服务器行为——正确性、语义、重构安全性、构建集成、协议面和可测量性能。  
**不在范围：** 编辑器与安装生态。两者都支持主流编辑器和安装方式；本文不比较该维度。

---

## 1. 摘要

本文说明 zig-analyzer 相比 ZLS 0.17.0 改进了什么，并给出可复现的测量方法与确定性案例。它不是“zig-analyzer 在所有维度都更好”的结论；ZLS 仍然是成熟、轻量的服务器，在某些工作流中更合适。代价与反向优势见第 5、6 节。

主要改进：

1. **诊断来自 Zig 编译器，而不是启发式分析层。** zig-analyzer 定义并测试了与 `zig build` 的诊断一致性：文件、位置、severity、消息、notes、reference traces 逐项相同。ZLS 只能通过 build-on-save 获得编译器诊断，且需要项目有 `check` 步骤或显式开启。
2. **comptime 与泛型代码是“求值”的，不是“近似”的。** zig-analyzer 会执行 comptime 表达式，并根据调用点实例推断泛型函数体。在确定性 fixture 中，ZLS 对 `anytype` 值的成员访问返回空 hover/goto，并漏掉字段补全；zig-analyzer 解析出具体的 `u64` 字段及其声明。
3. **重构更安全。** 在跨文件方法调用测试中，ZLS 只返回 1 个引用，只重命名声明，调用点被破坏，`zig build check` 失败；zig-analyzer 找到 2 个引用，编辑两个文件，项目仍能编译。
4. **补全带语义，并能自动导入。** zig-analyzer 提供带 import 编辑的自动导入候选和成员路径补全；ZLS 没有符号级自动导入。
5. **ZON 是一等文件类型。** zig-analyzer 提供 ZON 大纲、类型化补全/goto/inlay hints、`build.zig.zon` schema 和依赖 hash 操作。ZLS 主要把 `.zon` 当作语法/格式化文件；对一个有效的 `build.zig.zon`，它返回 0 个文档符号。
6. **构建模型更深。** zig-analyzer 使用编译集合、按编译上下文分析、生成文件路径和子项目。ZLS 的构建配置会把根文件相同的模块合并，这是其源码注释承认的限制。
7. **暖态延迟通常更低。** 在 ZLS 源码项目上，zig-analyzer 的 goto p50 为 0.23 ms vs 0.52 ms，completion p50 为 0.44 ms vs 0.79 ms，初始化 0.67 ms vs 19.1 ms。在 zig-analyzer 源码项目上，goto p95 与 completion p50/p95 也更优。

主要代价是内存、二进制体积、默认诊断延迟（50 ms 防抖）、泛型代码的 hover 尾延迟，以及项目年龄。第 5–6 节给出量化。

---

## 2. 测量设置

| 项 | 值 |
|---|---|
| 操作系统 / 内核 | Arch Linux，7.3.4-zen2-2-zen |
| CPU / 内存 | Intel Core Ultra 7 255H，16 逻辑 CPU / 62 GiB |
| Zig | 0.17.1 |
| 构建 | 两者均为 `-Doptimize=ReleaseSafe` |
| zig-analyzer | `0.2.1+20.g7108016`，提交 `7108016` |
| ZLS | `0.17.0`，tag 提交 `542462c` |
| 项目 A | ZLS 0.17.0 源码，37,643 行 Zig；测量 `src/analysis.zig`（7,006 行） |
| 项目 B | zig-analyzer 源码，138,842 行 Zig；测量 `src/sema/infer.zig`（5,235 行） |
| 客户端 | 自建 LSP 3.17 客户端，UTF-8 position，串行请求，项目 A/B 各 3 轮 |

时延是端到端的：JSON 序列化、管道传输、服务端处理、客户端解析。暖态测量前有 6 s 稳定期和一轮预热。RSS 是工作负载结束后从 `/proc/<pid>/status` 读取的值，不是峰值。基准工具是自建 LSP 客户端，不属于本仓库。第 8 节列出研究局限。

**重要：** 每轮固定先运行 zig-analyzer、后运行 ZLS。顺序未随机化；若产生偏差，方向对 ZLS 有利（文件缓存更暖）。

---

## 3. 改进细节

### 3.1 诊断：构造上保证与编译器一致

zig-analyzer 发布的编译器诊断来自 Zig 构建系统协议返回的官方 `ErrorBundle`。其一致性定义是明确的：在相同磁盘内容、相同 Zig 版本、相同 build step 和参数下，诊断与 `zig build <step>` 逐项相同，包括位置、severity、消息文本、notes 和 reference traces。实时诊断使用官方 parser 与 AstGen 在进程内完成（当用户 Zig 版本与内置 AST 版本不同时，回退到 `zig ast-check` 子进程）。

ZLS 的实时诊断是 AstGen 诊断加上自己的 style/autofix 诊断。编译器/Sema 诊断需要 build-on-save：当 `build.zig` 声明 `check` 步骤时，ZLS 自动启用 build-on-save；否则用户要显式开启，且没有 `check` 步骤时只能跑默认步骤或不构建。

实测：

| 场景 | zig-analyzer | ZLS |
|---|---|---|
| 有 `check` 步骤，打开即出现语义类型错误 | **684 ms** 后出现，source `zig` | **383 ms** 后出现，source `zls` |
| 没有 `check` 步骤，同样错误 | **1.31 s** 后出现，source `zig` | **10 s 内无诊断** |
| `enable_build_on_save=false` | 仍报告编译器错误 | 只有 AstGen，无 Sema 错误 |

**意义：** 类型错误、缺失字段、链接失败正是用户保存后最需要看到的东西。要求 `check` 步骤或显式构建开关，会让这种正确性变成有条件的。

### 3.2 comptime 与泛型实例

zig-analyzer 有 comptime 解释器和实例模型：泛型函数体按调用点产生的实例推断，comptime 分支会被求值而不是近似。ZLS 有类型分析器和 InternPool，但其 README 明确写着 comptime 与语义分析仍是 WIP。

确定性 fixture：

```zig
fn show(x: anytype) void {
    std.debug.print("{d}\n", .{x.value});
}

fn Box(comptime T: type) type {
    return struct {
        value: T,
        pub fn get(self: @This()) T { return self.value; }
    };
}

const Chosen = if (builtin.os.tag == .linux) u32 else u64;

pub fn main() !void {
    const b = Box(u64){ .value = 7 };
    show(b);
    ...
}
```

| 查询 | zig-analyzer | ZLS 0.17.0 |
|---|---|---|
| `show` 内 `x.value` 的 hover | `value: u64`，带调用点 | `null` |
| `x.` 后的补全 | `get`、`value` | 只有 `get` |
| `value` 的 goto | `Box` 中的字段声明 | `null` |
| `Box.get` 内 `self.value` 的 hover | `value: u64` | `value: T` |
| `Chosen` 的 hover | `type = u32` | 同时显示 `u32` 和 `u64` |

ZLS 并非完全没有调用点推断：对 `identity(x: anytype)` 以 `u32` 调用，它会显示 `x: anytype` 加 `(type = u32)`。差距具体在 `anytype` 值的成员访问、泛型容器字段、comptime 分支选择。

**意义：** 泛型和 comptime 密集代码在 Zig 标准库、allocator、序列化、编译期配置中很常见。服务器在这些位置返回 `null`，用户只能回去读源码。

### 3.3 重构安全性

zig-analyzer 在模块图和用户文件中搜索引用；当引用无法确认或新名字有歧义时拒绝 rename，并用 AstGen 校验重命名后的文件。ZLS 的引用搜索范围更窄。

具体测试：`widget.zig` 声明 `pub fn resize(...)`；`main.zig` 调用 `w.resize(4)`。在声明处请求 references/rename：

| 指标 | zig-analyzer | ZLS |
|---|---|---|
| references（含声明） | **2** | **1** |
| rename 编辑的文件数 | **2** | **1** |
| rename 后 `zig build check` | **通过** | **失败** |

ZLS 的失败信息：

```text
src/main.zig:38:6: error: no field or member function named 'resize' in 'widget.Widget'
    w.resize(4);
    ~^~~~~~~
```

即使 `main.zig` 已经打开并给服务器 5 s 稳定时间，结果仍然相同。为隔离 rename 的影响，测试副本把与重命名无关的 `var never_mutated` 改为 `const`，两个服务端同样处理。ZLS 没有找到跨文件方法调用，却仍然返回 rename 编辑而不是拒绝。这是正确性问题，不是风格偏好。

**意义：** rename 如果静默漏掉调用点，就把一次重构变成了构建失败。一个“不确定时拒绝”的服务器比“总是返回编辑”的服务器更有用。

### 3.4 补全与自动导入

zig-analyzer 的补全基于推断和名称解析，提供：

- 作用域内名称，带模糊排序和期望类型加权；
- 本地值的成员，包括 `sema.gpa` 这样的成员路径；
- 未导入声明的自动导入候选，附带 import 编辑；
- 调用、语句、声明片段；
- `completionItem/resolve`，选中时再计算签名和文档。

ZLS 有语义补全和片段，但没有符号级自动导入。它的 completion item 不带 `additionalTextEdits`；在运行时测试中，未导入的 `add` 从未被提供；zig-analyzer 在后台索引就绪后提供了它，并附带 import 编辑。

成员访问补全召回率：

| 项目 | zig-analyzer | ZLS |
|---|---|---|
| A（ZLS 源码） | 90/90 = **100%** | 90/90 = **100%** |
| B（zig-analyzer 源码） | 70/70 = **100%** | 64/70 = **91.4%** |

ZLS 在 B 上的未命中都是需要跨调用/容器类型推断的成员访问。样本小、置信区间有重叠，但上面的确定性 fixture 显示同一方向。

**意义：** 在每份文件都以 `@import` 开始的语言里，自动导入是日常操作。没有它，用户必须记住模块路径并手写 import。

### 3.5 ZON

zig-analyzer 把 `.zon` 当作一等文件类型：

- 任意 `.zon` 文件的解析、格式化和诊断；
- 根表达式的 outline；
- 对带结果类型导入的 `.zon` 文件提供类型化补全、goto、inlay hints；
- `build.zig.zon` 的 manifest schema 补全；
- `zig-analyzer.zon` 的设置补全和选项说明；
- 对依赖 URL 运行 `zig fetch` 并写入 hash 的 code action。

ZLS 能格式化 `.zon`，也有一些语法支持，但多处语义功能对 `.zon` 直接返回 `null`（signature help、inlay hints、references）；在测试中，一个有效的 `build.zig.zon` 返回 **0** 个文档符号，而 zig-analyzer 返回 **5** 个（`name`、`version`、`fingerprint`、`minimum_zig_version`、`paths`）。

在测试中，两者的格式化输出都与 `zig fmt` 对一个未格式化的 `.zig` 和 `.zon` 文件逐字节一致。格式化不是差异点；ZON 语义支持才是。

**意义：** `build.zig.zon` 是项目清单。没有 schema 补全、outline 和 hash 辅助，编辑它更慢、更容易出错。

### 3.6 构建系统集成

zig-analyzer 是 `zig build --listen=-` 的客户端：构建图、编译步骤、模块、生成文件、编译器诊断都来自这里。它维护编译集合，按编译上下文分析共享文件，按实际缓存解析生成路径，并加载子项目（带自己的 `build.zig` 且通过 `.path` 依赖根项目的 examples/benchmarks）。

ZLS 也集成构建系统，但其构建配置会合并根文件相同的模块；源码注释称这是一个限制。在评测版本中，它没有等价的子项目加载机制。

**意义：** 在同时有 host tool 和交叉编译 target 的项目中，或带 examples 的库中，同一个文件可能在不同 `builtin`/模块设置下编译。合并这些上下文的模型可能给出不完整或错误的导航。

### 3.7 协议面

zig-analyzer 暴露了一些 ZLS 没有的 LSP 细节：

| 能力 | zig-analyzer | ZLS 0.17.0 |
|---|---|---|
| `completionItem/resolve` | 有 | 无 |
| semantic tokens delta | 有 | 无（只有 full/range） |
| code action resolve | 有 | 无 |
| 依赖 hash 的 `executeCommand` | 有（客户端支持 `workspace/applyEdit` 时） | 无 |
| `zig-analyzer/packages` 检查请求 | 有 | 无 |
| `willSaveWaitUntil` | 无 | 有，但仅作为 `force_autofix` 兜底 |

关于 `willSaveWaitUntil`：ZLS 的实现不是通用保存管线。它只在 `force_autofix` 开启时使用（默认 false），只处理手动保存，只应用 `source.fixAll`。它是给“不支持 code action on save 的客户端”的兼容路径。zig-analyzer 改为暴露 `source.fixAll` 和 `source.organizeImports`，由编辑器在保存时调用。对现代客户端，这更可预测，也不会阻塞保存请求。

### 3.8 配置与团队设置

zig-analyzer 约有 44 个用户设置，使用嵌套 JSON/ZON，覆盖自动导入上限、命名规则、未使用声明、inactive code、缓存大小、子项目、日志和诊断防抖。项目相关设置可放在项目根的 `zig-analyzer.zon`，支持注释、类型校验、补全和 hover 文档。

ZLS 有 22 个扁平设置，`zls.json` 从全局/本地配置目录加载。它更简单，但对希望把项目设置提交到仓库的团队表达力更弱。

**意义：** 大型项目常需要按仓库配置构建参数、诊断步骤、命名策略。一个经过校验、带文档的项目根文件，比编辑器特定的 JSON 更容易维护。

### 3.9 可测量的性能优势

暖态中位数，每个单元格 3 轮：

| 项目 | 指标 | zig-analyzer | ZLS | 说明 |
|---|---|---|---|---|
| A | `initialize` | **0.67 ms** | 19.1 ms | ZLS 在返回前解析 Zig/构建配置 |
| A | hover p50 / p95 | **0.37 / 1.91 ms** | 0.58 / **1.31 ms** | ZLS 尾延迟更好 |
| A | completion p50 / p95 | **0.44 / 3.85 ms** | 0.79 / 4.16 ms | |
| A | goto p50 / p95 | **0.23 / 0.46 ms** | 0.52 / 1.04 ms | |
| A | semantic tokens full | **49.5 ms** | 70.2 ms | token 集不同，仅量级比较 |
| A | edit → diagnostics p50 | 56.2 ms | **6.0 ms** | 50 ms 防抖；关闭后 7 ms |
| A | RSS | 127.1 MiB | **60.9 MiB** | |
| B | `initialize` | **0.83 ms** | 48.1 ms | |
| B | hover p50 / p95 | 0.52 / 3.42 ms | 0.52 / **1.18 ms** | |
| B | completion p50 / p95 | **0.91 / 2.71 ms** | 1.88 / 6.89 ms | |
| B | goto p50 / p95 | **0.37 / 0.54 ms** | 0.40 / 0.92 ms | |
| B | edit → diagnostics p50 | 58.2 ms | **5.4 ms** | |
| B | RSS | 127.8 MiB | **66.5 MiB** | |

项目 A 上固定 250 个请求的 CPU 探针：

| 指标 | zig-analyzer | ZLS |
|---|---|---|
| 墙钟时间 | **244 ms** | 341 ms |
| CPU 时间 | **190 ms** | 250 ms |
| 每请求 CPU | **0.76 ms** | 1.00 ms |

性能结论不是“zig-analyzer 永远更快”，而是：

- 初始化握手快得多；
- goto/completion 的 p50 和 p95 通常更低；
- 固定工作负载下每请求 CPU 更低；
- 但内存和二进制更大；
- 更大项目上的 hover 尾延迟更差；
- 默认诊断更慢，因为 50 ms 防抖（可配置）。

### 3.10 可观测性与发布安全

zig-analyzer 通过 `std.log` 记录日志，支持运行时级别过滤和可选日志文件。`log.slow_request_ms` 会为慢请求打印查询分解（例如 `ParseFile`、`DeclType`、`Infer` 的 self time），让性能工作和 bug 报告有具体依据。Release 构建是 ReleaseSafe：bug 时停止服务器并给出堆栈，而不是静默返回错误结果；发布产物包含调试信息。发布还用 minisign 签名，并带构建来源 attestation。

ZLS 有标准 stderr 日志和成熟的运维经验，但没有同等粒度的慢请求查询分解，也没有明确的“宁可崩溃也不返回错误结果”策略。

**意义：** 语言服务器是基础设施。它出问题时，日志就是产品。查询级耗时和 fail-fast 策略能缩短诊断时间。

---

## 4. 证据表

| 主张 | 证据 | 注意 |
|---|---|---|
| 编译器一致诊断 | `docs/diagnostics.md` 的定义；15/15 交叉检查（项目自报）；有/无 `check` 步骤的实测 | 15/15 未在本机独立复现 |
| comptime/泛型解析 | fixture：`x.value` hover/goto/completion、`Chosen` 分支 | 小 fixture，不是语料库研究 |
| 更安全的 rename | fixture：ZLS 1 个引用、构建失败；zig-analyzer 2 个引用、构建通过 | 只覆盖一种跨文件方法调用模式，不代表所有 rename |
| 自动导入 | 源码：ZLS 无 `additionalTextEdits`；运行时：未导入的 `add` 未被提供 | 索引是异步的，第一次补全可能不完整 |
| ZON 大纲 | 有效 `build.zig.zon`：5 vs 0 个符号 | 单个 manifest 文件 |
| 构建模型 | 源码：编译集合、子项目；ZLS 的模块合并注释 | 未在多 target 项目上基准测试 |
| 暖态延迟 | 3 轮，每指标 30–180 个样本 | 单机；顺序未随机化 |
| 内存/二进制 | `/proc` RSS；`strip --all`；`size` | 不是峰值 RSS；单一工作负载 |
| 长会话稳定性 | 40 轮编辑：zig-analyzer 86.3 MiB 稳定；ZLS 27.4 → 45.4 MiB | 40 轮较短；ZLS 增长可能是缓存预热 |
| CPU 效率 | 250 请求：0.76 vs 1.00 ms/请求 | 单次运行 |

---

## 5. ZLS 仍然更强的地方

一份可信的“改进文档”必须列出另一面。

1. **内存：** 项目 A 上 ZLS 60.9 MiB vs 127.1 MiB；项目 B 上 66.5 MiB vs 127.8 MiB，约为一半。40 行 fixture 上是 14.4 MiB vs 49.0 MiB。
2. **二进制体积：** 完整文件 20.1 MB vs 48.6 MB；stripped 3.5 MB vs 7.7 MB。
3. **默认诊断延迟：** AstGen 诊断 5–6 ms，zig-analyzer 默认 50 ms 防抖下为 56–58 ms。设 `diagnostics.debounce_ms=0` 可到约 7 ms，但这不是默认值。
4. **更大项目上的 hover 尾延迟：** 项目 B 上 ZLS p95 1.18 ms vs 3.42 ms。zig-analyzer 的泛型实例工作有长尾。
5. **项目 B 的 hover p50：** 0.52 ms 持平，不是 zig-analyzer 的胜利。
6. **项目 B 的 semantic tokens：** ZLS 32.0 ms vs 38.6 ms。
7. **简单性与成熟度：** 22 个扁平设置 vs 约 44 个嵌套设置；长期部署历史；更小的学习和运维面。对普通代码和资源受限机器，ZLS 是合理默认。
8. **Zig master：** ZLS master 面向 Zig 0.18.0-dev；zig-analyzer 0.2.1 面向 Zig 0.17.0/0.17.1。如果跟踪 Zig master，ZLS 是实际可用的选择。

这些不抵消上面的语义优势；它们定义了代价，以及 ZLS 更合适的场景。

---

## 6. 从 ZLS 迁移的注意事项

1. **配置形态：** ZLS 是 22 键扁平 JSON；zig-analyzer 是嵌套 JSON/ZON，项目设置放 `zig-analyzer.zon`。
2. **保存时操作：** 用编辑器的 code-action-on-save 调用 `source.fixAll` 和 `source.organizeImports`。不要把 `willSaveWaitUntil` 当作替代；ZLS 的那个能力是 `force_autofix` 兜底，不是通用保存管线。
3. **诊断：** zig-analyzer 通过构建系统在加载/保存时编译，预期会有初次项目加载和更高内存占用；作为交换，Sema 错误不依赖 `check` 步骤。
4. **Rename：** zig-analyzer 更严格。它拒绝时不要盲目绕过；拒绝通常意味着引用有歧义或字符串字面量提到了该名字。
5. **性能调优：** 如果 50 ms 诊断防抖太慢，设 `diagnostics.debounce_ms=0`；如果内存紧张，检查 `sema.max_intern_pool_mb` 和 `cache` 限制。
6. **编辑器设置：** 两者都支持主流编辑器；使用现有编辑器集成和 on-save 钩子，而不是新增服务器端 pre-save workaround。

---

## 7. 测量说明

- 两个服务端均用 Zig 0.17.1 从源码构建，`ReleaseSafe`。
- 时延是端到端 LSP 时延；暖态测量前有 6 s 稳定期和一轮预热。
- 项目 A/B 各运行 3 次。第 3.9 节报告的是中位数，附录列出每次运行。
- RSS 是工作负载结束后的 `VmRSS`，不是峰值。
- 每轮：60–100 个 hover 样本、40–60 个 goto 样本、20–30 个 completion 样本、2–3 轮编辑到诊断。
- 基准工具是自建 LSP 客户端，不属于本仓库；第 8 节列出研究局限。

## 8. 局限

- 单机、Linux x86-64、Zig 0.17.1；未测 macOS/Windows。
- 两个真实项目加一个小 fixture；两者都是语言服务器/编译器基础设施代码，泛型密集，可能高估 zig-analyzer 的优势。
- 样本量小（每指标 30–180）；比例指标的 Wilson 区间较宽。
- 每轮固定先跑 zig-analyzer、后跑 ZLS；顺序未随机化，可能对 ZLS 有利。
- ZLS 使用 0.17.0 tag，不是 0.17.x 分支最新提交；后续修复未纳入。
- 性能测试关闭了 ZLS build-on-save，而 zig-analyzer 编译器诊断开启；初始化工作量不同。
- `willSaveWaitUntil` 的评估来自源码和少量运行时探测，不是广泛的客户端矩阵。
- 项目自报验证（97 库、10,305 文件语料、15/15 诊断、372/372 格式化）已标注，未在本机独立复现。

## 附录：逐次测量数据

### 项目 A：ZLS 源码，`src/analysis.zig`

| Run | Server | init ms | hover p50/p95 | completion p50/p95 | goto p50/p95 | edit p50 | semtok ms | RSS KiB |
|---|---|---|---|---|---|---|---|---|
| 1 | za | 0.674 | 0.368/1.911 | 0.467/4.021 | 0.233/0.408 | 56.419 | 49.5 | 130,496 |
| 2 | za | 0.768 | 0.393/1.946 | 0.440/3.854 | 0.266/0.462 | 55.806 | 45.0 | 130,168 |
| 3 | za | 0.648 | 0.328/1.692 | 0.378/3.692 | 0.224/0.816 | 56.188 | 50.0 | 123,344 |
| 1 | zls | 19.075 | 0.584/1.320 | 0.987/5.111 | 0.523/1.218 | 8.587 | 70.2 | 62,744 |
| 2 | zls | 19.451 | 0.633/1.063 | 0.729/4.155 | 0.595/1.037 | 6.023 | 86.1 | 61,004 |
| 3 | zls | 13.836 | 0.554/1.314 | 0.789/3.753 | 0.442/0.724 | 5.379 | 39.4 | 62,380 |

### 项目 B：zig-analyzer 源码，`src/sema/infer.zig`

| Run | Server | init ms | hover p50/p95 | completion p50/p95 | goto p50/p95 | edit p50 | semtok ms | RSS KiB |
|---|---|---|---|---|---|---|---|---|
| 1 | za | 0.83 | 0.76/2.52 | 0.91/2.41 | 0.66/0.88 | 58.2 | 31.8 | 132,100 |
| 2 | za | 0.95 | 0.23/3.42 | 0.66/2.71 | 0.06/0.40 | 56.9 | 38.6 | 129,708 |
| 3 | za | 0.65 | 0.52/3.81 | 1.11/4.47 | 0.37/0.54 | 58.5 | 48.2 | 130,828 |
| 1 | zls | 55.0 | 0.51/1.18 | 1.25/6.89 | 0.43/0.92 | 5.3 | 59.4 | 71,960 |
| 2 | zls | 38.6 | 0.53/1.33 | 2.00/8.16 | 0.40/1.07 | 6.2 | 32.0 | 68,056 |
| 3 | zls | 48.1 | 0.52/0.75 | 1.88/4.04 | 0.36/0.71 | 5.4 | 29.8 | 67,840 |

单位：时间毫秒；RSS 为 KiB。`za` 是 zig-analyzer，`zls` 是 ZLS。

---

## 结论

当**语义正确性、编译器一致诊断、安全重构、自动导入、ZON/构建集成**比内存、二进制体积和 50 ms 默认诊断延迟更重要时，选 zig-analyzer。  
当**低资源占用、成熟简单的服务器、即时 AstGen 诊断、轻量设置**更重要，且代码主要是普通 Zig、没有大量泛型/comptime 模式时，选 ZLS。
