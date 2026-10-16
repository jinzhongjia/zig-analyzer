# zig-analyzer 设计目标、性能指标与验收

zig-analyzer 是面向 Zig 0.17 的语言服务器（LSP）。当前阶段：功能完成，进入生产前的大规模真实项目验证。

---

## 1. 设计目标

1. **增量**：查询式引擎（依赖追踪 + early cutoff），跨请求复用结果；只改函数体不使其他函数的分析失效。
2. **容错**：任何输入（含半截代码）都能得到无损语法树与尽可能多的语义信息；推不出的结果为 `unknown`，传播但不报错、不猜测。
3. **语义正确优先**：泛型与类型构造用真正的 comptime 求值，而非模式匹配；泛型函数体内没有具体实例时取调用点的实例推导。
4. **低延迟**：编辑不被读请求阻塞，过期请求可取消。
5. **诊断与编译器 100% 一致**：诊断只来自 Zig 官方实现，自身的语义分析只服务于 IDE 功能，永不发布错误诊断（定义见 §3）。
6. **构建集成**：经官方构建系统协议（`zig build --listen=-`）获取项目模型，不维护自定义 build runner；无 `build.zig` 时按单文件降级可用。

### 非目标

- 分析结果的磁盘持久化（冷启动预算已满足，见 §2）。
- 调试器、测试运行器等非 LSP 功能。

### 设计原则

1. **一切皆查询**：除输入外，所有派生数据都是纯函数 query，由引擎缓存与失效。
2. **签名与函数体分离**：声明骨架（ItemTree）不含函数体，是最重要的 early cutoff 点。
3. **稳定 ID**：缓存 key 不依赖随编辑平移的下标（AstId、成员内的相对位置）。
4. **未知是一等公民**：用户代码的任何问题都是数据（`ERROR` 节点、`unknown`），不是错误，也不转化为诊断。
5. **复用官方实现**：格式化、解析错误、AstGen 直接用 `std.zig`；语义错误由编译器进程产出。

---

## 2. 性能目标与现状

测量工具：`zig build bench -Doptimize=ReleaseSafe -- <项目> <文件>...`（见 §5.2）。

### 2.1 目标与达成情况

基准项目：Zig 0.17.0 编译器源码（54 万行 + 标准库），代表最大规模的工作区。

| 场景 | 指标 | 目标 | 现状 | 状态 |
|---|---|---|---|---|
| 热状态 | hover / goto p95 | < 50 ms | ≤ 1.3 ms（首轮最慢 34 ms） | ✅ |
| | completion p95 | < 100 ms | ≤ 0.9 ms（首轮最慢 13 ms） | ✅ |
| | 编辑 → live 诊断 | < 30 ms（不含防抖） | 普通文件 ≤ 9 ms；`Sema.zig`（3.5 万行）p50 177 ms（含 50 ms 防抖） | ⚠️ 超大文件 |
| | 按键 → hover（连续输入） | — | `Sema.zig` p50 97 ms；其他项目 5～21 ms | — |
| | 保存 → 编译器诊断（`check` step） | < 1 s | 小项目约 120 ms；Zig 编译器 5.2 s | ⚠️ 受编译器限制 |
| | 常驻内存（长时间会话） | < 500 MB | 40 轮后 459 MB，峰值 476 MB | ✅ |
| 冷启动 | 进程启动 → `initialize` | < 100 ms | 1～9 ms | ✅ |
| | 打开文件 → 语法功能 | < 200 ms | 53 ms（`Sema.zig`） | ✅ |
| | 打开文件 → hover / goto / completion | < 3 s | 项目加载 1.5～4.4 s，加载完成前 hover 已可用（名字解析不完整） | ✅ |
| | 工作区符号索引（后台） | < 30 s | 1.9 s | ✅ |

### 2.2 真实项目

| 项目（测量文件） | 规模 | hover p50 | 补全 p50 | 编辑 → 诊断 p50 | 按键 → hover p50 | 常驻内存 |
|---|---|---|---|---|---|---|
| Zig 0.17.0 编译器（`src/Sema.zig`） | 54 万行 + std | 2.8 ms | 1.5 ms | 177 ms | 97 ms | 459 MB |
| ghostty（`src/terminal/Terminal.zig`） | 37 万行 | 1.6 ms | 1.2 ms | 118 ms | 21 ms | 112 MB |
| ZLS（`src/analysis.zig`） | 5.7 万行 | 0.7 ms | 0.5 ms | 90 ms | 16 ms | 218 MB |
| superhtml（`src/html/Tokenizer.zig`） | 4.3 万行 | 0.5 ms | 0.7 ms | 65 ms | 11 ms | 97 MB |
| zigimg（`src/color.zig`） | 3.8 万行 | 0.3 ms | 0.4 ms | 80 ms | 9 ms | 163 MB |
| z2d（`src/compositor.zig`） | 3.6 万行 | 0.4 ms | 0.3 ms | 72 ms | 9 ms | 142 MB |
| libvaxis（`src/Vaxis.zig`） | 2.5 万行 | 0.2 ms | 0.3 ms | 59 ms | 5 ms | 232 MB |
| http.zig（`src/httpz.zig`） | 1.5 万行 | 0.5 ms | 0.4 ms | 64 ms | 9 ms | 105 MB |
| zig-clap（`clap.zig`） | 0.3 万行 | 0.2 ms | 0.3 ms | 62 ms | 5 ms | 84 MB |
| 97 个库批量校验 | — | 中位数 0.3 ms，最大 6.0 ms | — | — | — | 中位数 64 MB，最大 181 MB |

编辑 → 诊断均含 50 ms 防抖。

### 2.3 已知差距

- **超大文件的编辑 → 诊断**：`Sema.zig` 上主要耗时是重新解析（约 54 ms）、官方 AstGen（约 48 ms）与推导整个文件以求非活动代码区间；关闭 `diagnostics.inactive_code` 时约 85 ms。
- **超大文件的按键 → hover**：每次按键后需重新解析并重建 ItemTree、FileIndex，`Sema.zig` 上约 100 ms 为下限。
- **保存 → 编译器诊断**：耗时在编译器本身；`-fincremental` 在 0.17 中会漏报错误，默认不开启。
- **引用查找冷启动**：被大量文件引用的声明最坏 1.9 s（候选文件超过解析缓存容量而反复解析）；热状态 p95 124 ms。

---

## 3. 诊断一致性的定义

对**同一份磁盘内容、同一 Zig 版本、同一构建 step 与构建参数**，发布的诊断与 `zig build <step>` 的输出逐条相等：

- 文件、起止位置（ErrorBundle 的 span）完全一致；
- 级别、文案逐字一致，note 与 reference trace 一一对应（映射为 `relatedInformation`）；
- 不多报（未被分析的泛型函数体、不在编译集合中的文件），不漏报（含链接错误）。

| 来源 | 触发 | 实现 |
|---|---|---|
| `live` | 编辑（防抖 50 ms） | 进程内 `std.zig.Ast` + AstGen；用户 zig 版本与内置标准库不同时改用 `zig ast-check` |
| `compiler` | 保存 | 构建系统协议回传的 `ErrorBundle`；无 `build.zig` 时为 `zig build-obj -fno-emit-bin --listen=-` |

- 只对编译集合（从各 compile step 根模块沿 `@import` 可达的文件）发布 live 诊断。
- 有未保存修改时：live 诊断基于缓冲区，编译器诊断基于已保存内容并按编辑增量平移位置。

---

## 4. 设计要点

### 4.1 分层

```
server/    LSP 主循环、调度、取消、工作区与项目管理、配置
ide/       hover · completion · goto · refs · rename · inlay hints · code actions …
ide_db/    文件索引（FileIndex）· 引用查找
sema/      InternPool · 类型推导 · comptime 解释器 · 类型渲染
hir/       函数体 IR 降级 · 局部作用域
names/     模块图 · import / 名字解析
syntax/    容错无损 CST · 局部重解析 · ItemTree · AstId · 类型化访问层
diagnostics/ live（官方解析器 + AstGen）· compiler（ErrorBundle）· 编译集合
db/        查询引擎
base/      Vfs · URI · 输入 · ProjectModel
project/   构建系统协议客户端 · zig env · builtin.zig 生成
lsp/       由 metaModel.json 生成的类型 · JSON-RPC · 传输
```

每层只依赖下层；全部 query 在 `database.zig` 中注册为一个 `Db` 类型。

### 4.2 查询引擎（`db/`）

- **红绿验证 + early cutoff**：memo 记录 `verified_at` / `changed_at` 与依赖；输入变化后逐个验证依赖，重算得到相等的值时保留旧 `changed_at`，下游不重算。
- **Durability**：std 与依赖包为 high，验证时整体跳过不变的层。
- **增量计算**：query 可声明 `computeIncremental(ctx, key, prev)`，重算时拿到上一次的值（用于局部重解析）。
- **环与深度**：每线程维护活动查询栈，遇到环调用 query 的 `cycleFallback`，环中的结果不写 memo；嵌套计算占用原生栈超过 4 MB 时同样回退，并以迭代加深分段计算深链。每个读事务有 comptime 求值的总步数预算（2000 万步）。
- **取消**：写事务到来时置位，读查询在 `get` 入口返回 `error.Canceled`，被取消的计算不写 memo；读请求回复 `ContentModified`。
- **内存回收**：query 可声明 `lru`（个数）与 `lru_bytes`（字节数），淘汰只删值、保留依赖；`resetQueries` 整代清空类型相关的 query（与 `InternPool.reset` 配合）。
- 引擎内只传播 `Canceled`、`OutOfMemory` 两类错误；query 结果是自包含的不可变值，只存 ID 不存指向其他 memo 的指针。

### 4.3 语法层（`syntax/`）

不直接用 `std.zig.Ast` 作 IDE 语法树：它对 `foo.` 这类半截表达式恢复粒度粗、不保留 trivia 结构、节点下标全局平移无法局部重解析。

- **红绿树 CST**：手写递归下降，以官方 PEG 语法为准，永不失败，错误处产出 `ERROR` 节点；无损（树文本拼接等于原文）。
- **局部重解析**：编辑落在花括号平衡的 `block` / `container_decl` 内时只重解析该节点，其余绿节点复用；结果必须与全量解析完全相同（语料与随机编辑测试保证）。
- **ItemTree**：文件声明骨架（名字、种类、标志、签名哈希），不含函数体；只改函数体时值不变，名字层与签名推导都不失效。
- **AstId**：由父 AstId + 种类 + 名字 + 同名序号得到，跨编辑稳定；函数体内节点用 HIR 的 `ExprId` 定位。
- **类型化访问层**（`ast.zig`）：手写，集中「某信息位于哪个子节点」的知识，访问器返回可选值。
- `std.zig.Ast` 只用于格式化与 AstGen 诊断。

### 4.4 名字层与 HIR（`names/`、`hir/`）

- **模块图**：来自构建图，附加 `std`、`builtin`（按模块参数运行 `zig --show-builtin` 生成）、`root`；一个文件可属于多个模块。无构建图时每个文件自成模块 + std。
- **名字解析**：局部作用域 → 词法外层容器链；`a.b.c` 沿 `@import`、容器定义、`@This()` 与别名链求命名空间。
- **HIR**：函数体、初始化表达式、comptime / test 块、字段类型与默认值都是 BodyOwner，降级为容错的表达式 IR（不用 ZIR：有语法错误时不生成），同时算出局部作用域；成员源码未变时沿用上一次的 Body。

### 4.5 语义层（`sema/`）

- **InternPool**：类型与 comptime 值的唯一表示，相同 Key 得到相同 Index；超过 `sema.max_intern_pool_mb` 时整代回收，之后按需重新推导。容器类型的身份不依赖字段类型，递归类型不会成环。
- **核心 query**：`DeclType`（声明的类型与 comptime 值，只读签名）、`Infer`（BodyOwner + 实例 → 每个表达式的类型与解析目标）、`CallEval`（comptime 调用按实例与实参记忆化）、`ErrorSetOf`（推导错误集）、`LocalValue`（单个局部绑定）。
- **推导**：双向推导对应 Zig 的结果类型语义，期望类型从参数、返回值、标注、字段初始化下推；分支汇合做 peer type resolution；`unknown` 吸收一切。
- **comptime 解释器**：在 HIR 上执行，支持算术（按位宽回绕 / 饱和 / 溢出检查）、控制流、函数调用、容器构造、`@typeInfo` 与 `@Struct` / `@Enum` 等类型构造 builtin；单次求值 20 万步、64 MB 上限；遇到运行时值、外部函数、`@cImport` 为 `unknown`。std 的泛型容器、`std.meta` 等因此无需特判。
- **泛型函数体**：没有具体实例时以抽象实例推导（`comptime T: type` 为抽象参数，显示为 `T`）；**调用点种子**取一个能求出具体实例的调用点推导（经文件索引跨文件查找，最多传递 3 层），hover 标注来源。
- **目标相关**：指针位宽等从各模块的 builtin.zig 求出（`TargetAbi`），目标变化时依赖它的结果失效。

### 4.6 IDE 层（`ide/`、`ide_db/`）

| 功能 | 依据 |
|---|---|
| semantic tokens / folding / selection range / document symbol | 纯语法 |
| formatting | `std.zig.Ast.render`，与 `zig fmt` 逐字一致 |
| goto definition / declaration / type definition、hover、completion、signature help、inlay hints | 推导结果 + 名字解析 |
| references / document highlight / rename | `FileIndex` 按名字粗筛文件 → `ItemSummaries` 的布隆过滤器粗筛成员 → 逐处精确解析确认 |
| workspace symbol | 后台为全部项目文件建索引，未完成时返回已索引部分 |
| code actions | 以编译器诊断的 span 为锚点（丢弃未使用参数等）与 CST 构造编辑 |
| 非活动代码 | comptime 已知不执行的分支 |

### 4.7 构建集成（`project/`）

- 直接作为官方构建系统协议 `zig build --listen=-` 的客户端：握手校验 `build_system_version`，读取 `bsp_configuration` 中的构建图（`std.Build.Configuration`）转换为 ProjectModel，按 step 请求构建并从 `bsp_step_completed` 取 `ErrorBundle` 与生成文件路径；`bsp_configuration_failed` 作为 `build.zig` 的诊断发布。
- 同一进程同时承担项目模型与编译器诊断；崩溃后退避重启，`build.zig` 变化时由 maker 重新配置，完成前沿用旧模型。
- 版本耦合：`Configuration` 格式与进程内 AstGen 都来自 zig-analyzer 编译时的标准库，用户 zig 版本不同时降级（单文件模式 / `zig ast-check`）。发布版本跟随 Zig 版本。

### 4.8 服务器与并发（`server/`）

- 写消息（文档同步、配置、工作区与文件监听事件）串行执行：置取消标志 → 等读者退出 → 应用变更、推进 revision。
- 读请求在快照上并发执行；`$/cancelRequest` 与写事务都可取消。
- 诊断发布：编辑触发的按文件防抖，被更新的编辑取代时放弃；AstGen 在读事务之外预先计算，不阻塞写事务。编译进行中保留上一轮结果，完成后原子替换。
- 配置来自客户端（`initializationOptions`、`workspace/configuration`），项目根的 `zig-analyzer.json` 可覆盖与项目相关的项；各项说明见 `src/server/Config.zig`。
- 可观测性：`zig-analyzer/status` 暴露各 query 的执行次数、命中率、耗时与内存；慢请求日志（`log.slow_request_ms`）；`-Dtracy=<目录>` 开启 tracy。

---

## 5. 验收方式

### 5.1 自动化测试（CI，Linux / macOS / Windows）

| 命令 | 内容 |
|---|---|
| `zig build test`（Debug 与 ReleaseSafe） | 单元与端到端测试：引擎（增量、cutoff、环、取消、淘汰）、语法、名字、sema、IDE 功能、构建系统协议与诊断一致性 |
| `zig build test --fuzz=<次数>` | 覆盖率引导模糊测试：URI ↔ 路径、解析器无损、增量与全量解析一致、位置换算 |
| `zig build corpus -- <目录>...` | 解析器语料对拍：无损、无误报、与 `std.zig.Ast` 结构一致、截断不崩溃、HIR 降级无失败 |
| `zig fmt --check`、`zig build gen` 后无 diff | 格式与生成代码 |

- `zig build sema-corpus`：在标准库上做全量类型推导，检验不崩溃并统计类型已知的比例。
- 测试向 stderr 写日志时 `zig build test` 也会打印 `failed command: ...`，退出码为 0 即通过；真正的失败带有「N pass, M fail」与测试名。

### 5.2 真实项目基准与对拍

```
zig build bench -Doptimize=ReleaseSafe -- <项目根目录> <文件（相对项目根）>...
```

以子进程启动服务器、按编辑器的方式交互，测量冷启动、hover / goto / completion 延迟、编辑 → 诊断、连续输入、内存。环境变量开启各项校验（详见 `tools/lsp_bench.zig` 头部）：

| 变量 | 校验 | 通过标准 |
|---|---|---|
| `BENCH_CHECK=<n>` | 对标识符请求 declaration，目标处名字应与请求处相同 | 不一致 = 0 |
| `BENCH_COMPLETE=<n>` | 源码中的 `a.b` 在 `.` 后补全，列表中应有 `b` | 召回 ≥ 95% |
| `BENCH_REFS=<n>` | 查找引用与重命名 | 名字不符、误报、遗漏、重命名不一致均为 0 |
| `BENCH_SAVE=1` | 保存 → 编译器诊断，与 `zig build` 逐条比较 | 完全一致 |
| `BENCH_SESSION=<轮数>` | 长时间会话的内存 | 稳定，不超过预算 |
| `BENCH_QUICK=1` | 跳过编辑相关阶段，用于批量校验 | — |

另以 `zig fmt` 对拍 `textDocument/formatting`（逐字一致）。

### 5.3 当前验收结果（2026-10-16）

| 范围 | 结果 |
|---|---|
| 97 个 Zig 0.17.0 库（zls、zigimg、libvaxis、zine、microzig、Cubyz、flow、raylib 等）批量校验 | 崩溃 / 超时 0；declaration 不一致 0（解析率中位数 88.5%）；引用与重命名错误 0；补全召回中位数 99.7%，81 / 97 ≥ 95%；hover p50 中位数 0.3 ms；常驻内存中位数 64 MB、最大 181 MB |
| 语料对拍（8438 个文件、182.5 MB） | 全部通过；10 万次随机编辑下增量与全量解析无不一致 |
| 编译器诊断对拍 | 15 / 15 一致 |
| 格式化对拍 | 372 / 372 个文件一致 |

召回低于 95% 的库主要因依赖未能取得而没有构建图；其余为 `@cImport` 与经多层泛型的 comptime 反射类型。
