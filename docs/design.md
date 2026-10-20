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
| 97 个库批量校验 | — | 中位数 0.2 ms，最大 1.0 ms | — | — | — | 中位数 93 MB，最大 308 MB |

编辑 → 诊断均含 50 ms 防抖。

语义着色另以 `docs/test-list.md` 的 97 个指定文件串行测量（ReleaseSafe，项目加载完成、调用点推导开启）：
热 full p95 5.83 ms，注释插入/撤销后的 delta p95 10.12 ms、最大 20.71 ms，热 range p95 0.38 ms。
Cubyz、strand、flow、element-0 的首次 10 行 range 为 0.31～2.89 ms；空 range 不执行 Infer / seed 查询。

### 2.3 已知差距

- **超大文件的编辑 → 诊断**：`Sema.zig` 上主要耗时是重新解析（约 54 ms）、官方 AstGen（约 48 ms）与推导整个文件以求非活动代码区间；关闭 `diagnostics.inactive_code` 时约 85 ms。
- **超大文件的按键 → hover**：每次按键后需重新解析并重建 ItemTree、FileIndex，`Sema.zig` 上约 100 ms 为下限。
- **保存 → 编译器诊断**：耗时在编译器本身；`-fincremental` 在 0.17 中会漏报错误，默认不开启。
- **引用查找冷启动**：被大量文件引用的声明最坏 1.9 s（候选文件超过解析缓存容量而反复解析）；热状态 p95 124 ms。
- **`error.Foo` 跳转的冷启动**：期望的错误集不对应某个声明（推导的错误集、`A || B`）或这个名字没有声明时，要为整个 import 闭包建立文件索引；本仓库的 `src/server/Server.zig` 上首次约 0.3 s，之后文件索引常驻、不再重复。
- **语义着色首次全量请求**：泛型实例与异构循环的按需推导仍有冷开销，97 库中最大 861 ms；该值不含项目加载，不能用热请求或小范围请求的延迟替代。

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

- 只对编译集合（从各 compile step 根模块沿 `@import` 可达的文件）与构建脚本（根目录的 `build.zig`、`build.zig.zon`，以及 `build.zig` 沿相对路径 `@import` 可达的文件，项目实例启动时按文件的当前文本计算）发布 live 诊断。文件属于多个项目时，其中一个项目包含它即发布。
- 官方解析器与 AstGen 逐层递归（Debug 构建每层约 16 KB 栈）。先按 token 估计嵌套深度的上界：不超过 256 在当前线程做，不超过 102400 在 2 GiB 栈的专用线程上做；更深的文件不做 AstGen，没有 live 诊断，import 按 token 收集。上限按常见的嵌套形式（else-if 链、if 表达式链、括号、调用、初始化、运算符链）标定，比它更深时 `zig ast-check`（主线程栈 46 MiB）同样耗尽栈。
- 附注与引用链映射为 `relatedInformation`：引用链的各项排在附注之后，有位置的项指向引用处，文案为 `referenced by: <名字>`；隐藏计数项位于错误起点，文案与 `zig build` 相同。`@compileLog` 的输出以 `Compile Log Output:` 加各行接在 `found compile log statement` 错误的文案后；同一编译中还有其他错误而没有这条错误时，接在第一条错误后。
- 子进程回传的 `ErrorBundle`（`bsp_step_completed`、`bsp_configuration_failed` 与单文件编译的结果）使用前校验全部下标与字符串：消息列表、各条消息与逐层的附注、源位置与其后的引用链都在 `extra` 内，字符串下标指向以 0 结尾的字符串，引用链中隐藏标记的计数不当作字符串；嵌套深度与读取总量有上限，自引用与环被拒绝。头部给出的长度超出消息体时整条消息按格式错误处理，不按这个长度分配内存。不合法时丢弃并记录日志，按这次编译没有错误处理，同一消息中的生成文件与读取的文件照常使用。路径解析后不是绝对路径时（Windows 上另一驱动器的相对路径，如 `D:a.zig`）不作为文件：错误包中的按没有位置处理，`file_system_inputs` 中的跳过。行列与区间等数值不校验：终点在起点之前的区间改为起点处的空区间，按编辑平移后超出范围的诊断不发布。
- 文件的来源（`server/origin.zig`）依次判断：
  - 获取的依赖包：模块所在的、按哈希获取的包（包目录的 `<哈希>` 子目录，包目录默认为 `<构建根>/zig-pkg`，随 `--pkg-dir`、`--system` 改变）；
  - 生成文件：全局缓存与各项目的本地缓存；
  - 用户代码：工作区根目录下的文件，不含其中的 `.zig-cache`、`zig-pkg`（Zig 安装目录位于根目录下时是在开发 Zig 自身，同样是用户代码）；
  - Zig 安装目录（标准库、`lib/compiler` 等）；
  - 用户代码：根目录外但属于某个项目的模块（以路径加入的模块、`--fork` 指定的包）。
  - 获取的依赖包、生成文件与 Zig 安装目录合称依赖库。编译上下文、durability（§4.2）、重命名（§4.6）、服务端监听（§4.8）与 workspace symbol 的范围都由这一份分类得出。
- 文件的编译上下文依次判断（编译入口只来自项目与独立文件，打开文件本身不产生编译入口）：
  - 依赖库；
  - 项目：在某个项目的模块图中（编译集合，或可由其余 compile step 到达），包括构建根目录外以路径加入的模块；
  - 项目目录：带 `build.zig` 的根目录下、不在模块图中的文件；
  - 未加载的项目：祖先目录有 `build.zig`、那个项目却没有加载的 `.zig` 文件（工作区外另一个项目中的文件，根目录没有 `build.zig` 时根目录之上或之下的项目中的文件）。按名字的 import 只有那个项目的构建能解析，所以不单独编译；与 rust-analyzer 对不属于任何 crate 的文件相同，打开时只给出一条 Hint，提示把项目目录加入工作区。查找祖先目录时遇到 `.zig-cache`、`zig-pkg` 即停止（其中是缓存与获取的依赖包，不是外层项目的源码）。提示在启动阶段结束、项目首次加载完成之后才发布，理由同单文件模式推迟编译；
  - 其余 `.zig` 文件为独立文件，各自作为根编译（单文件模式）。关闭构建集成时没有项目、项目目录与未加载的项目。
  - 路径只做词法规范化，不解析符号链接；前缀比较的大小写规则与文件身份一致。
- 编译器诊断取包含文件的各个项目最近一次构建的结果；单文件编译的结果用于依赖库、独立文件与不属于项目的其他文件，不用于项目、项目目录与未加载的项目中的文件（它们被独立文件按相对路径 import 时处在另一个模块中，按名字的 import 与项目中不同）。有多个结果时合并：以最新一次编译读取的文本为准，文本不同的结果只取非 AstGen 错误并按差异平移，区间与文案相同的只保留一条。
- 保存或在磁盘上修改一个文件时，包含它的各个项目都重新构建（构建脚本则重启项目）；它自身是独立文件时重新编译，上一次编译读取过它（编译器的 `file_system_inputs`，限根文件所在目录）或在其中报告过错误的根也重新编译。
- 单文件模式：
  - 结果中被 import 的文件里的错误发布到那些文件上（含标准库），打开与未打开的都发。
  - 启动阶段结束（zig 环境就绪、项目开始加载）之前，以及有项目尚在首次加载（读入构建图并算出编译集合之前）时，推迟编译：此时还不知道根目录外的文件是否属于项目。
  - 文件的上下文可能变化时收敛（zig 环境就绪，项目加载结束、编译集合变化、新实例替换旧实例，项目与根目录的增删，构建集成与编译器诊断的开关）：不再是独立文件的根丢弃结果，推迟了的编译以及打开的、没有编译过的独立文件补上编译。
  - 根文件不在磁盘上时（重新编译或关闭时发现它已被删除）丢弃它的结果。
- 有未保存修改时：live 诊断基于缓冲区，编译器诊断基于已保存内容并按编辑增量平移位置。

---

## 4. 设计要点

### 4.1 分层

```
server/       LSP 主循环、调度、取消、工作区与项目管理、配置
ide/          hover · completion · goto · refs · rename · inlay hints · code actions …
ide_db/       引用查找 · 调用点种子
sema/         InternPool · 类型推导 · comptime 解释器 · 类型渲染
names/        模块图 · import / 名字解析
hir/          函数体 IR 降级 · 局部作用域
syntax/       容错无损 CST · 局部重解析 · ItemTree · AstId · 类型化访问层 · 文件索引（FileIndex、ErrorSets）
diagnostics/  live（官方解析器 + AstGen）· compiler（ErrorBundle）· 编译集合
project/      构建系统协议客户端 · 子进程 ErrorBundle 的校验 · zig env · builtin.zig 生成
base/         Vfs · URI · 输入 · ProjectModel
db/           查询引擎
util/         各层共用的工具：LSP 位置换算、结构比较、内存统计、日志
lsp/          由 metaModel.json 生成的类型 · JSON-RPC · 传输
```

- 每层只依赖下层；测试可以引用上层，以驱动端到端的场景。
- 全部 query 在 `database.zig` 中注册为一个 `Db` 类型。names 及以上的层经它取得 `Db.Ctx` 与下层的 query。

### 4.2 查询引擎（`db/`）

- **红绿验证 + early cutoff**：memo 记录 `verified_at` / `changed_at` 与依赖；输入变化后逐个验证依赖，重算得到相等的值时保留旧 `changed_at`，下游不重算。
- **Durability**：写入文件内容时按文件的来源（§3）设置：Zig 安装目录与获取的依赖包为 high，生成文件为 medium，其余为 low；验证时整体跳过不变的层。没有写入、在查询中按需从磁盘读取的文件（如单文件模式下的标准库）为 low。验证通过的 memo 取依赖当前的最低 durability（输入降低 durability 而值经 early cutoff 不变时，下游不能仍按高 durability 跳过验证）。
- **增量计算**：query 可声明 `computeIncremental(ctx, key, prev)`，重算时拿到上一次的值（用于局部重解析）。
- **环与深度**：每线程维护活动查询栈，遇到环调用 query 的 `cycleFallback`；嵌套计算占用原生栈超过 4 MB 时同样回退，并以迭代加深分段计算深链。每个读事务有 comptime 求值的总步数预算（2000 万步）。
  - 环中的结果不写 memo，读取方也不把它记为依赖：它读到的依赖直接交给栈上最近的不在环中的帧。环入口的 memo 因此直接依赖环内各成员读到的 query 与 input，memo 之间不成环，成员旧 memo 的 early cutoff 也不会掩盖入口看到的变化。
  - 燃料耗尽或栈深度回退时，栈上的 query 都不写 memo，环中的依赖也不再向它们传递，深递归的回退保持线性代价。
  - 验证时依赖经由环回到栈上 query 的 memo，在那个 query 出栈前视为无法验证：读取时直接重算，验证其他 memo 时视为已变化。环中每个 memo 只验证一次，重算代价与首次计算相当。
- **取消**：`pending_write` 是等待独占锁的写事务数，非零时读查询在 `get` 入口返回 `error.Canceled`，被取消的计算不写 memo；读请求回复 `ContentModified`。写事务拿到锁后才减一，重叠的写事务不会清掉彼此的登记。
- **内存回收**：query 可声明 `lru`（个数）与 `lru_bytes`（字节数），淘汰只删值、保留依赖；`resetQueries` 整代清空类型相关的 query（与 `InternPool.reset` 配合）。
- 引擎内只传播 `Canceled`、`OutOfMemory` 两类错误；query 结果是自包含的不可变值，只存 ID 不存指向其他 memo 的指针。

### 4.3 语法层（`syntax/`）

不直接用 `std.zig.Ast` 作 IDE 语法树：它对 `foo.` 这类半截表达式恢复粒度粗、不保留 trivia 结构、节点下标全局平移无法局部重解析。

- **红绿树 CST**：手写递归下降，以官方 PEG 语法为准，永不失败，错误处产出 `ERROR` 节点；无损（树文本拼接等于原文）。
- **局部重解析**：编辑落在花括号平衡的 `block` / `container_decl` 内时只重解析该节点，其余绿节点复用；结果必须与全量解析完全相同（语料与随机编辑测试保证）。
- **深度上限**：语法树最深 1024 层，沿树递归的各层（HIR 降级、推导、语义 token 等）因此有上限；解析器在未结束的节点达到 2048 个时不再递归，括号配平地把所在结构包进错误节点。触及上限的文件之后的编辑都全量解析。标准库与 `lib/compiler` 中最深的文件为 319 层。
  - 更深的节点在构造绿树时展平：token 直接挂在第 1024 层的节点下（仍然无损），这一层的节点改为错误节点。其中的代码不参与名字解析与推导，语义着色也不按外层节点的种类猜测分类。
  - 文件索引记下出现在这样的代码中的名字：那里的引用无法确认，名字出现在其中时拒绝重命名，查找引用只返回确认的部分。
- **ItemTree**：文件声明骨架（名字、种类、标志、签名哈希），不含函数体；只改函数体时值不变，名字层与签名推导都不失效。
- **AstId**：由父 AstId + 种类 + 名字 + 同名序号得到，跨编辑稳定；函数体内节点用 HIR 的 `ExprId` 定位。
- **位置无关摘要**：`ItemNames` 保存成员的名字布隆过滤器，`ContainerRels` 保存容器相对 owner 的位置；绝对位置留在 `ItemSummaries` / `FileAstIdMap` 中，避免仅移动源码使语义搜索失效。
- **类型化访问层**（`ast.zig`）：手写，集中「某信息位于哪个子节点」的知识，访问器返回可选值。
- `std.zig.Ast` 只用于格式化与 AstGen 诊断。

### 4.4 名字层与 HIR（`names/`、`hir/`）

- **模块图**：来自构建图，附加 `std`、`builtin`（按模块参数运行 `zig --show-builtin` 生成）、`root`。
  - 文件的归属来自各 compile step 的编译集合。一个文件可属于多个模块（如 exe 与 test 各自创建模块、共用根文件），按名字的 import 依次在这些模块的 import 表中查找。
  - 多个模块以同一名字 import 不同目标时，名字解析（成员、hover、补全等）取最优先的模块：诊断 step 在前，其中本机目标在前，其余 compile step 按构建图的顺序（可用 `diagnostics.step` 改变）。不按位置区分，test 块中不会改用 test 模块的同名 import。光标在 `@import` 或它的字符串上时，跳转（definition / declaration）返回全部目标，按同样的优先级排列；别名的使用处仍跳到 `const x = @import(...)` 声明。`@import("root")` 与 `builtin` 按最优先的归属。
  - 不属于任何模块的文件（单文件模式、不在任何编译集合中的文件、项目加载期间的文件）只能 import std 与相对路径，`builtin` 为本机目标、Debug。`@import("root")` 为 `unknown`：文件可能由另一个文件以相对路径 import，也可能由 `zig test` 编译（根文件是测试运行器），标准库又由所有这类文件共用；经 `@hasDecl(root, ...)` 读取的值（`std.options` 等）因此为 `unknown`，不产生非活动代码。
- **名字解析**：局部作用域 → 词法外层容器链；`a.b.c` 沿 `@import`、容器定义、`@This()` 与别名链求命名空间。
- **HIR**：函数体、初始化表达式、comptime / test 块、字段类型与默认值都是 BodyOwner，降级为容错的表达式 IR（不用 ZIR：有语法错误时不生成），同时算出局部作用域；成员源码未变时沿用上一次的 Body。

### 4.5 语义层（`sema/`）

- **InternPool**：类型与 comptime 值的唯一表示，相同 Key 得到相同 Index；超过 `sema.max_intern_pool_mb` 时整代回收，之后按需重新推导。容器类型的身份不依赖字段类型，递归类型不会成环。
- **核心 query**：`DeclType`（声明的类型与 comptime 值，只读签名）、`Infer`（BodyOwner + 实例 → 每个表达式的类型与解析目标）、`CallEval`（comptime 调用按实例与实参记忆化）、`ErrorSetOf`（推导错误集）、`LocalValue`（单个局部绑定）。
- **推导**：双向推导对应 Zig 的结果类型语义，期望类型从参数、返回值、标注、字段初始化下推；分支汇合做 peer type resolution（含枚举字面量与枚举、`&.{}` 与切片），没有结果类型的分支中的枚举字面量按 peer 类型解析（`if (t) |x| x.kind else .invalid`）；`unknown` 吸收一切。调用处判断是否为泛型调用只读被调函数的参数形式（`ParamForms`），只改被调函数的函数体时调用者不重新推导。
  - anytype 形参收到的枚举字面量在被调函数的实例中被转换成的类型（每个参数取函数体中第一处）记入推导结果，调用处的字面量引用其中的成员：`testing.expectEqual(.x, actual)` 经 `@TypeOf(expected, actual)` 转换为 actual 的类型。
  - switch 的操作数 comptime 已知时，执行的分支的捕获取实际的载荷值；各项的载荷类型没有 peer 时（只能是 `inline .@"struct", .@"union" => |info|` 这样每项单独实例化的分支）类型也取实际的载荷类型。
- **comptime 解释器**：在 HIR 上执行，支持算术（按位宽回绕 / 饱和 / 溢出检查）、控制流、函数调用、容器构造、`@typeInfo` 与 `@Struct` / `@Enum` 等类型构造 builtin；遇到运行时值、外部函数为 `unknown`。std 的泛型容器、`std.meta` 等因此无需特判。构造类型（`@Struct` / `@Enum` / `@Union`）以构造它的函数实例命名（`FieldEnum(S)`）；不在函数中构造、正是某个常量的值时以常量命名。
  - 跳转到构造类型的成员（字段访问 `x.name`、`E.name`、枚举字面量 `.name`）：名字是 comptime 求出的字符串。来自字符串字面量时（如 zig-clap 解析帮助文本得到的字段名），以跟踪字面量来源的方式重新求值：字符串字面量放在独立的存储单元中，切片保持对它的引用，得到名字在字面量中的位置；候选为初始化表达式含有这个字面量的常量，以及使用处与构造处所在成员的局部绑定。来自 `@typeInfo(X)` 时（`@typeInfo(Tag).@"enum".field_names`）跳到 X 的同名成员。
  - 单次求值 20 万步，`@memcpy` 与经由切片的整体写入每个元素计一步。内存上限 64 MB，单个聚合至多 65536 个元素：展开聚合（复制、拼接、切片、`@splat` 等）之前按已占用容量加本次分配检查，其余每 256 步检查一次。
  - 指向局部存储的切片以「存储单元 + 路径 + 区间」表示，取元素与长度时在原聚合中直接读取，不复制区间。
  - 驻留的值至多嵌套 256 层（自引用的值按 `unknown`）。
- **泛型函数体**：没有具体实例时以抽象实例推导（`comptime T: type` 为抽象参数，显示为 `T`；`comptime x: anytype` 的实例记录实参值）；**调用点种子**取一个能求出具体实例的调用点推导，hover 标注来源：
  - 经文件索引跨文件查找；调用者自身在泛型函数内时取调用者的实例，hover / 跳转 / 补全最多上溯 6 层，收集全部实例（查找引用、重命名）最多 3 层（每层取调用者的全部实例，实例数随层数成倍增长）
  - 函数值与实参元组一起传入的调用（`Thread.spawn(.{}, f, .{ a, b })`、`@call(.auto, f, .{ a })`）以元组元素作为实参
  - 项目中没有调用点的泛型方法以标准库的分派处求实例：`std.Io.Writer.printValue` 中的 `value.format(w)`、`value.formatNumber(w, ...)` 等
  - 抽象参数的 `@hasDecl` / `@hasField` 结果未知（推导与解释器一致），依赖它们的 comptime 分支不判为非活动；抽象实例中的容器（如 `@This()`）有哪些成员只取决于源码，仍给出确定结果
  - 选择实例：hover / 跳转 / 补全和语义着色共用按 owner 复用的 `Refiner`，按位置选择代码活动且目标类型具体的实例。候选按固定层级尝试，优先前 8 个实例，再做有界扩展；与异构循环迭代组合搜索，都求不出类型时保留活动分支的容错结果。
  - 调用者以自己的 comptime 类型参数调用目标（`P.name(...)`）时只用调用者的真实实例：没有以目标容器实例化的调用点，就不存在编译器生成的实例，保持抽象（未知），不按目标容器拼出实例
  - 目标所在的容器作为 comptime 类型实参传入泛型函数、再经类型参数调用目标（查询引擎中 `ctx.get(Q, key)` → … → `Q.compute(ctx, key)`）：分派处所在的文件不必 import 目标所在的文件，按导入链找不到。从实参中传入这个容器类型的调用出发，逐层进入实参中仍含有它的泛型调用，直到调用目标处；收集全部实例时同样沿这条路径查找
  - 每次迭代的循环变量类型不同的循环：遍历 comptime 已知的类型列表（`inline for`，comptime 中的 `for`；循环变量是抽象的类型），或遍历各项类型不同的元组（`inline for (.{ &posix, &windows }) |cases|`；循环变量的类型求不出）。光标处的表达式求不出类型、或调用位于这样的循环中时按单次迭代推导（至多 64 次迭代），同一循环的其他循环变量（`for (types, 0..) |T, i|`）取这次迭代的值与类型；hover 标注 `inferred from iteration <n> of the loop at <位置>`
  - 搜索缓存保存调用者 owner、表达式身份与实例，展示时才换算绝对位置；导入闭包与候选名字查询跨成员复用。实参、声明、导入和项目配置仍是失效依赖，位置性编辑不重复深层搜索。
- **其他构建配置**：当前配置下不存在的成员（只在其他目标上编译的代码，如 `posix.system.EVFILT.READ`、macOS 的 `settings.cflag.CCTS_OFLOW`）到其他配置的容器中查找：沿别名与 comptime 条件的 `if` / `switch` 分支收集各配置下的容器；实例的类型沿局部变量、全局变量、调用的返回类型与字段类型收集。
- **目标相关**：与目标相关的参数从各模块的 builtin.zig 解析出的目标（架构、操作系统、ABI、CPU 特性）求出（`TargetAbi`），目标变化时依赖它的结果失效；参数相同的模块共用同一份 builtin.zig，每份只读取、解析一次。
  - 参数包括指针位宽、向量的布局规则、整数的最大对齐、`c_char` 的符号，以及 C 类型与 `f32` / `f64` / `f80` / `f128` 的大小、对齐与位宽，按编译器 `Type.abiAlignment` / `abiSize` 的规则计算：C 类型用 `std.Target.cType*`，整数用 `std.zig.target.intAlignment` / `intByteSize`，浮点按 C 类型、表示它的整数或 compiler-rt 的软浮点表示。
  - 各模块的目标不一致时只保留一致的部分：最大整数对齐取区间，只有对齐不受它影响的整数有确定的布局，其余各项为 `unknown`。builtin.zig 读不到时只有不超过 1 字节的整数有确定的布局；没有任何 builtin 时按分析器自身的目标。
  - std 没有定义的值为 `unknown`：AVR 的 32 位 `long double`，以及 ps3 / contiki / managarm 的 C 类型。

### 4.6 IDE 层（`ide/`、`ide_db/`）

| 功能 | 依据 |
|---|---|
| folding / selection range / document symbol | 纯语法 |
| semantic tokens | CST 分类 + 每个成员的名字解析与类型推导；引用与声明共用类型、绑定和成员信息，无法解析的代码保留语法分类 |
| formatting | `std.zig.Ast.render`，与 `zig fmt` 逐字一致；嵌套深的文本在 2 GiB 栈的专用线程上格式化，深到 `zig fmt`（主线程栈 46 MiB）也耗尽栈时拒绝（估计深度超过 36864，按常见的嵌套形式标定；连续的前缀运算符 `zig fmt` 能格式化得更深） |
| goto definition / declaration / type definition、hover、completion、signature help、inlay hints | 推导结果 + 名字解析 |
| 内置函数的补全、hover、参数提示 | 同版本 Zig 官方语言参考生成的静态签名、参数和 Markdown 说明；hover 同时保留推导结果 |
| `error.Foo` 的跳转与 hover | 在 `error{ ... }` 声明中查找：成员与期望的错误集完全相同的优先，其次是期望错误集的一部分（`A \|\| B` 中的 `A`），再次是任何含这个名字的；先查当前文件，再查沿 `@import` 可达的文件（以 `FileIndex` 按名字筛选），直到找到不会被取代的（没有期望的错误集时为第一个）；各文件的错误集声明按文件记忆（`ErrorSets`），重复查找不重新解析 |
| references / document highlight / rename | `FileIndex` 按名字粗筛文件 → `ItemNames` 的布隆过滤器粗筛成员 → 逐处精确解析确认；候选文件为能经 `@import` 链到达定义的项目文件（定义在标准库或依赖包中时，链可以经过范围外的文件） |
| workspace symbol | 后台为全部项目文件建索引（ItemTree 与 `ItemSummaries`）；按 ItemTree 匹配名字，名字的位置取自 `ItemSummaries`（值很小、不淘汰），查询不需要解析结果；未完成时返回已索引部分。默认不列出依赖库中的符号，由 `workspace_symbol.dependencies` 开启 |
| code actions | 以编译器诊断的 span 为锚点（丢弃未使用参数等）与 CST 构造编辑 |
| 非活动代码 | comptime 已知不执行的分支；comptime 已知为 noreturn 的语句（条件 comptime 已知成立的 `if (...) return ...;`、被选中的 `@compileError`）之后的语句；左侧 comptime 已知、决定结果的 `and` / `or` 的右侧 |

重命名只修改用户自己的代码（§3 的文件来源）：依赖库中的定义不能重命名。

内置元数据固定为 Zig 0.17.0，来源、源码包及输入文件哈希记录在 `tools/zig/metadata.json`，许可保留在同目录。
`zig build gen` 离线生成 `src/ide/builtin_data.zig`，校验官方输入哈希、编译器版本、名称和参数数量；运行时只查静态表。
128 个编译器登记项中，124 个有官方文档；其余 4 个明确说明来源缺口，不编造签名，也不提供虚假的参数提示。

语义着色的约束：

- **分类**：按实际类型与绑定区分类型、命名空间、变量、函数、方法和成员，不按名字猜测。抽象声明分类独立缓存，类型别名的声明及引用按当前位置的实例细化，不跨实例回写。转义标识符遵循词法作用域，裸内建名与 `_` 保留语言语义。
- **容错**：复用每个成员的候选实例与循环迭代结果，按 token 位置选择可解析的实例；受有界搜索限制，无法解析时保留语法着色，不按调用语法猜测函数。
- **未使用绑定**：按绑定身份统计词法引用，只对有函数体的参数、局部变量和捕获附加 `unused`。写入、asm 输出和显式丢弃算作使用；不据局部引用判断顶层声明或容器成员。只改变着色，不产生诊断；Neovim 使用主题的 `DiagnosticUnnecessary` 暗色。
- **编码与范围**：使用协商的位置编码，输出有序、单行、不重叠 token；空区间直接返回，其余按范围裁剪 CST 与 owner 分析，同时保留影响 `unused` 的范围外词法引用。返回相交的完整 token，坐标相对于文档起点。
- **增量与缓存**：支持 full、delta、range；delta 按整个 token 求公共前后缀，用两者之间的一段替换表示，无变化时返回空 edits，基线不可用时返回全量。只缓存已打开文档的最新快照，最多 128 个文档、16 MiB；关闭释放，重新打开隔离旧会话，range 不修改快照。
- **刷新**：客户端支持 refresh 时，语义依赖变化触发合并后的刷新请求。发出刷新后，此前的结果不再作为 delta 基线，各文档的下一次 delta 请求返回全量：Neovim 0.12 刷新时保留旧 resultId，同时请求 range 与 delta，先处理的 range 结果会替换它的基线。

### 4.7 构建集成（`project/`）

- 直接作为官方构建系统协议 `zig build --listen=-` 的客户端：握手校验 `build_system_version`，读取 `bsp_configuration` 中的构建图（`std.Build.Configuration`）转换为 ProjectModel，按 step 请求构建并从 `bsp_step_completed` 取 `ErrorBundle` 与生成文件路径；`bsp_configuration_failed` 作为 `build.zig` 的诊断发布。
- 构建图只包含 step 可达的模块。没有任何 compile step 的项目（只导出模块、由使用方编译的库）在 `.zig-cache/zig-analyzer/exports` 中生成探针包：以项目为 path 依赖，为每个导出的模块添加 object step，复用项目的 `zig-pkg`；读出的模块与 compile step 并入 ProjectModel，只用于模块归属，不出现在构建请求中。
- C 绑定由构建系统的 translate-c 生成（Zig 0.17 已移除 `@cImport`），作为以生成文件为根的模块，构建后得知路径。
- maker 以 `local_cache` 前缀上报的生成文件路径，以及构建图中相对于本地缓存的路径，都按 maker 实际使用的本地缓存目录解析：由 `bsp_configuration` 给出的构建图路径（`<本地缓存>/c/<hash>`，不使用缓存时为 `tmp/<hex>`）反推，因此遵循 `build.args` 中的 `--cache-dir` 与 `ZIG_LOCAL_CACHE_DIR`。重命名不修改这个目录中的生成文件；本地缓存目录包含构建根时无法区分生成文件与项目文件，不按它排除。
- 模块所在的依赖包中，根目录名就是包哈希的为获取的依赖包（maker 把获取的包存放在包目录的 `<哈希>` 子目录中），其根目录记入 ProjectModel，用于区分依赖的代码与用户的代码；`--fork` 指定的包使用用户给出的目录，不在其中。
- 同一进程同时承担项目模型与编译器诊断。重启以新实例进行：
  - 先结束项目当前实例与尚未替换它的新实例的 maker 及其子进程，再启动新实例。新实例在首次构建完成（或配置失败、不需要构建）时替换旧实例，其间旧实例的模型、编译集合与编译器诊断继续生效，构建请求转给新实例；旧实例没有模型与编译集合时，新实例算出编译集合后立即替换它。实例按引用计数回收。
  - 触发重启：根目录的 `build.zig`、`build.zig.zon`、`zig-analyzer.json` 以及构建脚本（`build.zig` 沿相对路径 `@import` 可达的文件）被保存或在磁盘上变化，构建配置变化，maker 崩溃（退避重启）。根目录下新建或删除 `build.zig` 时启动或停止项目。
  - 新实例被放弃（maker 连续崩溃超过上限、协议版本不符）时，旧实例的编译器诊断被清除、模型保留，直到再次保存 `build.zig`。读不了构建图时提示用户并停止 maker，直到保存 `build.zig`；`bsp_configuration_failed` 中没有错误（`build.zig.zon` 或依赖包的问题）时提示运行 `zig build` 查看原因。
- 进程管理：maker 与它启动的子进程在 POSIX 上属于以看门狗 `sh` 为组长的进程组，在 Windows 上属于设置了 `KILL_ON_JOB_CLOSE` 的 Job Object。停止项目（shutdown、exit、输入结束、重启）时整组立即结束，不等待构建；服务器以任何方式退出时整组随之结束。
- 版本耦合：`Configuration` 格式与进程内 AstGen 都来自 zig-analyzer 编译时的标准库。构建图文件没有版本号，按结构体逐字节读取，格式不符时会越界（握手校验的 `build_system_version` 只覆盖协议消息），所以只在用户 zig 的版本与编译时完全一致时读取。
  - 版本不同时，带 `build.zig` 的根目录不启动构建系统：没有编译器诊断，命名模块的 import（依赖包、构建选项）无法解析，只有 `zig ast-check` 的 live 诊断。这些根目录下的文件也不按单文件编译（使用命名模块的文件会报出找不到模块）。启动时提示用户两个版本与受影响的功能。
  - 其他文件仍按单文件模式编译，读取的是用户 zig 产出的 `ErrorBundle`。它的格式同样没有版本号：使用前按 §3 校验，不通过时丢弃；通过校验的包不会越界读取，但格式不符时诊断的内容可能错乱。
  - 发布版本跟随 Zig 版本。

### 4.8 服务器与并发（`server/`）

- 写消息（文档同步、配置、工作区与文件监听事件）串行执行：登记等待（取消计数加一）→ 等读者退出 → 应用变更、推进 revision。主循环处理消息与服务器发现的外部改动由同一个锁串行。
- 读请求在快照上并发执行；`$/cancelRequest` 与写事务都可取消。
- 诊断发布：编辑触发的按文件防抖，被更新的编辑取代时放弃；live 诊断（进程内 AstGen 与子进程 `zig ast-check`）在读事务之外计算，不阻塞写事务。编译进行中保留上一轮结果，完成后原子替换。编译结果创建后不再修改，按引用计数共享：发布时在持有者的锁内取得引用即释放锁，合并期间结果不会因被替换而释放，也不必复制。
  - 同一文件的发布任务并发计算，每次在读取状态之前取递增序号，只发送序号不小于已发送序号的结果。每次状态变化之后都会发起一次发布，最后发出的结果因此读到最后一次变化之后的状态。
- 配置来自客户端（`initializationOptions`、`workspace/configuration`），项目根的 `zig-analyzer.json` 可覆盖与项目相关的项；各项说明见 `src/server/Config.zig`。
- 退出：输入结束时不再等待客户端对配置请求的回复，停止各项目后退出。`initialize` 给出 `processId` 时等待客户端进程退出，之后服务器随之退出（stdin 的写端可能被客户端的其他子进程继承而一直不关闭）。等待使用操作系统的进程退出通知：Linux 用 pidfd（内核 5.3 起），macOS 与 FreeBSD、NetBSD、OpenBSD 用 kqueue 的 `EVFILT_PROC`，Windows 等待进程句柄；都用不了时（内核较旧、沙箱禁止、没有权限打开进程、其他平台）才每 2 秒检查一次进程是否还在。
- 外部改动：客户端支持动态注册时注册 `workspace/didChangeWatchedFiles`。客户端不支持时（Linux 上的 Neovim 默认如此），或 `files.watcher` 为 `server` 时，由服务器监听，变化按同一条路径处理：
  - 关注驻留过的 `.zig` / `.zon` 文件与各根目录的 `build.zig`、`build.zig.zon`、`zig-analyzer.json`，不含依赖库（§3）中的文件；打开的文档以缓冲区为准，跳过。
  - 用操作系统的原生通知监听这些文件所在的目录：Linux 用 inotify，macOS 用 FSEvents，Windows 用目录变化通知。目录不存在时监听最近一级存在的祖先目录，它出现后改为监听它自己，其中已经存在的文件按新建处理。驻留了新文件（Vfs 通知）、根目录增减、目录新建或删除、通知丢失时重新计算要监听的目录。一阵连续的通知合为一批（静默 50 ms，至多推迟 500 ms）。
  - 轮询（检查大小与修改时间）只作为最后的退路：原生通知不可用（其他平台、初始化失败），或个别目录超出监听数量上限（如 inotify 的 `max_user_watches`）时，只对这些目录中的文件轮询，间隔至少 1 秒，且不少于一次检查耗时的 20 倍。
  - 处理期间计为忙碌：重启项目时旧实例结束与新实例开始之间，等待空闲的一方不会返回。
  - 已知限制：在网络文件系统（NFS、SMB/CIFS、sshfs 等 FUSE）、WSL2 中的 Windows 侧文件（`/mnt/c`）、容器与虚拟机的共享目录上，原生通知收不到其他机器或宿主机上的改动，而加监听会成功，因此不会退回轮询，这些改动不会被发现（与 rust-analyzer 相同，不检测文件系统的类型）。
- 可观测性：慢请求日志（`log.slow_request_ms`）；`-Dtracy=<目录>` 开启 tracy。自定义请求（方法名带 `zig-analyzer/` 前缀，结果字段见 `server/Server.zig` 中各自的结果类型）：
  - `status`：各 query 的执行次数、命中率、耗时与内存，InternPool 与堆的占用。
  - `fileStatus`（参数 `textDocument`）：文件的来源（§3）、编译上下文（项目、项目目录、未加载的项目、依赖库、独立文件）、是否打开、所属模块的根、包含它的项目及其上一次构建（完成时间、文件数、诊断数）、以它为根或包含它的单文件编译根。
  - `syntaxTree`（参数 `textDocument`）：缩进的语法树（节点与 token）与语法错误。
  - `moduleGraph`：由各项目汇总的模块图：标准库的根，各模块的根文件、builtin、import 与文件数。
  - `reloadWorkspace`：重启全部项目，同保存 `build.zig`。
  - `waitIdle`：等到服务器空闲（构建、诊断发布等后台任务结束）才返回，供测试与基准使用。
- 崩溃：Zig 没有栈展开，panic 结束整个进程。退出前把消息、当前线程的上下文与调用栈写入日志：上下文包括主循环处理的消息、读请求的方法、文档与位置，发布诊断的文件、单文件编译的根、项目的构建事件、索引，以及正在计算的 query 栈。分析代码对输入数据的、可以降级的假设用软断言（`util/assert.zig`）：Debug 与测试中失败即 panic，其余构建中每处只记录一次日志并走降级路径。

---

## 5. 验收方式

### 5.1 自动化测试（CI，Linux / macOS / Windows）

| 命令 | 内容 |
|---|---|
| `zig build test-all`（Debug 与 ReleaseSafe） | 全部测试：引擎（增量、cutoff、环、取消、淘汰）、语法、名字、sema、IDE 功能，以及运行 PATH 中 zig 的构建系统协议、单文件编译、诊断一致性与端到端测试 |
| `zig build test --fuzz=<次数>` | 覆盖率引导模糊测试：URI ↔ 路径、解析器无损、增量与全量解析一致、位置换算 |
| `zig build corpus -- <目录>...` | 解析器语料对拍：无损、无误报、与 `std.zig.Ast` 结构一致、截断不崩溃、HIR 降级无失败 |
| `zig fmt --check`、`zig build gen` 后无 diff | 格式与生成代码 |

- `zig build test`：只运行不依赖外部工具的测试，供开发时快速验证。其中找不到 zig（`ZigEnv.query` 在这时返回 `ZigNotFound`），依赖它的测试（示例项目、真实的标准库）跳过，服务器不启动项目与编译。
- `zig build test-stress -Dstress-filter=<完整测试名的片段> [-Dstress-runs=<次数>]`：以服务模式依次反复运行指定的测试（默认 50 次，每次都实际运行），用于验证并发相关的改动。
- `zig build sema-corpus`：在标准库上做全量类型推导，检验不崩溃并统计类型已知的比例。
- 测试向 stderr 写日志时 `zig build test` 与 `test-all` 也会打印 `failed command: ...`，退出码为 0 即通过；真正的失败带有「N pass, M fail」与测试名。

### 5.2 真实项目基准与对拍

```
zig build bench -Doptimize=ReleaseSafe -- <项目根目录> <文件（相对项目根）>...
```

以子进程启动服务器、按编辑器的方式交互，测量冷启动、hover / goto / completion 延迟、编辑 → 诊断、连续输入、内存。环境变量开启各项校验（详见 `tools/lsp_bench.zig` 头部）：

| 变量 | 校验 | 通过标准 |
|---|---|---|
| `BENCH_CHECK=<n>` | 对标识符请求 declaration，目标处名字应与请求处相同；未解析的按种类（原始类型、`len` / `ptr`、错误名、`.` 字面量、成员访问、标签、名字）统计 | 不一致 = 0 |
| `BENCH_COMPLETE=<n>` | 源码中的 `a.b` 在 `.` 后补全，列表中应有 `b` | 召回 ≥ 95% |
| `BENCH_REFS=<n>` | 查找引用与重命名；泛型函数体中在其他调用点实例下指向同名声明的引用另计 | 名字不符、误报、遗漏、重命名不一致均为 0 |
| `BENCH_SAVE=1` | 保存 → 编译器诊断，与 `zig build` 逐条比较 | 完全一致 |
| `BENCH_SESSION=<轮数>` | 长时间会话的内存 | 稳定，不超过预算 |
| `BENCH_QUICK=1` | 跳过编辑相关阶段，用于批量校验 | — |

另以 `zig fmt` 对拍 `textDocument/formatting`（逐字一致）。

批量校验：每个库先 `zig build --fetch` 取得依赖，取根项目（不含自带 `build.zig` 的子目录、测试与示例）中成员访问最多的一个文件，以 `BENCH_QUICK=1 BENCH_CHECK=40 BENCH_COMPLETE=40 BENCH_REFS=20` 运行。项目、提交与测量文件见 `docs/test-list.md`。

### 5.3 当前验收结果

| 范围 | 结果 |
|---|---|
| 97 个 Zig 0.17.0 库（zls、zigimg、libvaxis、zine、microzig、Cubyz、flow、raylib 等）批量校验（2026-10-19） | 全部有构建图；崩溃 / 超时 0；declaration 不一致 0（解析率中位数 90.8%，排除没有声明位置的标识符后中位数 100%）；引用与重命名错误 0；补全召回中位数 100%，95 / 97 ≥ 95%；hover p50 中位数 0.2 ms、最大 1.0 ms；常驻内存中位数 93 MB、最大 308 MB |
| 语料对拍（10305 个文件、264.6 MB，2026-10-16） | 全部通过；12 万次随机编辑下增量与全量解析无不一致 |
| 编译器诊断对拍（2026-10-16） | 15 / 15 一致 |
| 格式化对拍（2026-10-16） | 372 / 372 个文件一致 |

召回低于 95% 的 2 个库：strand 中未补全的成员位于多层泛型的 comptime 反射代码中（如 `descriptor.options(T)` 的结果）；morse 的测试代码 import 的 `shakedown` 由默认配置下不存在的测试步骤添加，不在构建图中。
