# zig-analyzer 设计方案

> 状态：草案 v0.1 ｜ 实施进度：M0、M1、M2 已完成（2026-10-12），M3、M4 已完成（2026-10-13），M5、M6、M7 已完成（2026-10-14），下一步 v1.0，详见 §19。

---

## 1. 背景与目标

zig-analyzer 是一个面向 Zig 的语言服务器（LSP），目标是在编辑过程中提供快速、准确、可预测的语言智能。

Zig 的语言特性给 IDE 分析带来几个独特挑战，本设计围绕它们展开：

- **comptime 即泛型**：类型是 comptime 值，泛型容器由函数在编译期构造（`fn List(comptime T: type) type`），只做语法层面的模式匹配无法得到可靠结果；
- **惰性语义**：编译器只分析可达代码，未被调用的函数、未实例化的泛型函数在编译器中没有类型信息，而这正是编辑中最常见的状态；
- **结果类型驱动**：`.foo`、`.{...}`、`@intCast` 等表达式的类型取决于上下文的期望类型；
- **构建系统即代码**：模块图由 `build.zig` 在运行时决定，且 `std.Build` API 随版本演进；
- **编辑中的代码几乎总是不完整的**：语法错误是常态，分析必须容错。

### 目标

1. **增量**：查询式引擎，依赖追踪 + early cutoff，跨请求复用一切可复用结果。
2. **容错**：任何输入（包括半截代码）都能得到语法树与尽可能多的语义信息。
3. **语义正确优先**：用真正的 comptime 求值来处理泛型和类型构造，而非模式匹配猜测。
4. **低延迟**：编辑永远不被读请求阻塞；过期请求可取消。
5. **分层清晰**：每层只依赖下层，可独立测试。
6. **构建集成可持续**：项目模型是一等输入，版本适配隔离在单独模块。
7. **诊断与编译器 100% 一致**：报告的每一条错误都来自 Zig 官方实现（标准库解析器、AstGen、编译器本身），不多报、不漏报、文案与位置逐字一致（定义见 §11.1）。

### 非目标（v1）

- 分析结果的持久化磁盘缓存（v1 只做内存缓存并预留序列化能力，见 §6.7）。
- 调试器、测试运行器等非 LSP 功能。

### 性能预算（热状态，10 万行项目 + std）

| 操作 | p95 目标 |
|---|---|
| hover / goto | < 50 ms |
| completion | < 100 ms |
| 编辑 → 语法 / AstGen 诊断 | < 30 ms |
| 保存 → 编译器诊断（`-fincremental`，`check` step） | < 1 s |
| 常驻内存 | < 500 MB |

### 冷启动预算（无内存缓存，ProjectModel 磁盘缓存命中）

| 阶段 | 目标 |
|---|---|
| 进程启动 → 响应 `initialize` | < 100 ms |
| 打开文件 → 语法功能（高亮、折叠、大纲）可用 | < 200 ms |
| 打开文件 → hover / goto / completion 可用 | < 3 s |
| 工作区符号索引完成（后台，不阻塞交互） | < 30 s |

符号索引未完成时，workspace symbol 返回已索引部分并标记 `isIncomplete`；references / rename 退化为对未索引文件的实时扫描，结果仍然完整，只是更慢。

---

## 2. 设计原则

1. **一切皆查询**：除输入外，所有派生数据都是纯函数 query，结果由引擎缓存与失效。
2. **签名与函数体分离**：改函数体不影响任何其他函数的分析结果。
3. **稳定 ID**：缓存 key 不能依赖会随编辑平移的下标。
4. **未知是一等公民**：推不出来就是 `unknown`，`unknown` 传播但不报错、不猜测。
5. **诊断只来自官方实现**：自身的语义分析只服务于 IDE 功能，永远不发布错误诊断。
6. **复用 `std.zig` 与编译器进程，而非编译器内部代码**：格式化、解析错误、AstGen 直接用标准库；语义错误由编译器进程产出。

---

## 3. 总体架构

```
┌────────────────────────────────────────────────────────────────┐
│ server/     LSP 传输、主循环、调度、取消、能力协商                     │
├────────────────────────────────────────────────────────────────┤
│ ide/        hover · completion · goto · refs · rename · hints …   │  纯函数 (Snapshot, Pos) → Result
│ ide_db/     符号搜索 · 引用查找 · 编辑构造 · 类型渲染                  │
├────────────────────────────────────────────────────────────────┤
│ semantics/  对外语义门面（Semantics API）                            │
│ sema/       类型推导 · comptime 解释器 · 实例化 · builtin 规则         │  query
│ hir/        Body IR 降级 · 源映射 · 局部作用域                         │  query
│ names/      模块图 · 容器命名空间 · import / 名字解析                   │  query
│ syntax/     容错无损 CST · ItemTree · AstId                         │  query
├────────────────────────────────────────────────────────────────┤
│ db/         查询引擎：revision · memo · 依赖 · cutoff · 取消 · 环检测   │
│ base/       Vfs · ProjectModel · Config（input）                    │
├────────────────────────────────────────────────────────────────┤
│ project/    构建系统协议客户端（zig build --listen=-）· zig env         │  外部进程
│ lsp/        LSP 类型（由 metaModel.json 生成）· JSON-RPC             │
└────────────────────────────────────────────────────────────────┘
```

### 目录

```
src/
  main.zig      zig_analyzer.zig（库根）  database.zig（注册全部 query 的 Db 类型）
  lsp/          types.zig(生成) json_ext.zig jsonrpc.zig transport.zig
  server/       Server.zig（主循环、调度、取消、handler）
  db/           engine.zig（查询引擎）
  base/         Vfs.zig uri.zig inputs.zig ProjectModel.zig Config.zig
  util/         offsets.zig
  syntax/       kind.zig lexer.zig parser.zig grammar.zig green.zig tree.zig Parse.zig ItemTree.zig queries.zig
  names/        ModuleGraph.zig Namespace.zig resolve.zig
  hir/          Body.zig lower.zig SourceMap.zig Scopes.zig
  sema/         InternPool.zig infer.zig eval.zig instantiate.zig builtins.zig coerce.zig
  semantics/    Semantics.zig
  ide_db/       search.zig symbol_index.zig render.zig edits.zig
  ide/          document_symbol.zig folding.zig selection_range.zig semantic_tokens.zig format.zig（已实现）
                hover.zig completion.zig goto.zig references.zig rename.zig
                inlay_hints.zig signature_help.zig workspace_symbol.zig code_actions/
  diagnostics/  live.zig（已实现） Collector.zig compiler.zig remap.zig compile_set.zig
  project/      bsp_client.zig configuration.zig zig_env.zig
tools/
  gen_lsp_types.zig     # metaModel.json → lsp/types.zig
  gen_syntax.zig        # grammar.zon → syntax/ast.zig（类型化访问器）
  gen_builtins.zig      # builtins.zon → sema/builtins_data.zig
  gen_config.zig        # config.zon → base/Config.zig + schema.json + 文档
  corpus.zig            # 语料对拍：zig build corpus -- <目录>...
tests/
  fixtures/ syntax/ sema/ ide/ incremental/ corpus/ bench/
```

---

## 4. 输入层（`base/`）

输入是唯一可被外部写入的数据，写入推进全局 revision。

| Input | Key | Value | Durability |
|---|---|---|---|
| `file_text` | `FileId` | `[]const u8` | 工作区文件 = low；依赖包 = medium；std = high |
| `project_model` | — | `ProjectModel` | medium |
| `config` | — | `Config` | medium |

- **`FileId`**：`u32`，由 Vfs 分配，路径 ↔ ID 双向映射；路径规范化（大小写、符号链接）在 Vfs 内统一处理。
- **Vfs 来源合并**：客户端打开的文档优先；未打开的文件从磁盘懒读，并通过 `workspace/didChangeWatchedFiles` 或自带文件监听失效。
- **Durability**：std 与依赖包几乎不变，验证 high durability 的 memo 时可整体跳过依赖遍历（参考 salsa 的 durability 优化），对冷启动和大项目很关键。

### ProjectModel

```zig
pub const ProjectModel = struct {
    zig: struct { exe: []const u8, version: std.SemanticVersion, lib_dir: []const u8, std_dir: []const u8 },
    modules: []Module,         // 全部模块（含 std、builtin、依赖包模块）
    roots: []ModuleId,         // 各 compile step 的根模块
    steps: []Step,             // 供 build-on-save 选择

    pub const Module = struct {
        name: []const u8,
        root_file: []const u8,
        imports: []struct { name: []const u8, module: ModuleId },
        target: ?[]const u8,
        optimize: ?std.builtin.OptimizeMode,
        c_include_dirs: [][]const u8,
    };
};
```

---

## 5. 语法层（`syntax/`）

### 5.1 自研容错无损 CST（关键决策）

不直接用 `std.zig.Ast` 作为 IDE 语法树，原因：

- `std.zig.Ast` 错误恢复粒度粗：`foo.` 这类半截表达式常导致整条语句丢失，补全最需要的恰恰是这里；
- 不保留空白/注释的树结构，重构类功能（code action、rename 周边编辑）难做；
- 节点下标全局平移，无法局部重解析。

方案：**红绿树**（参考 rowan）。

```zig
// 绿树：不可变、无位置、可共享
pub const GreenNode = struct { kind: SyntaxKind, text_len: u32, children: []const GreenElement };
pub const GreenToken = struct { kind: SyntaxKind, text: []const u8 };   // 含 trivia token

// 红树：按需创建的游标，带 parent 与绝对偏移
pub const SyntaxNode = struct { green: *const GreenNode, parent: ?*const SyntaxNode, offset: u32 };
```

- **解析器**：手写递归下降，以 Zig 官方 PEG 语法为准；**永不失败**，错误处产出 `ERROR` 节点，缺失子节点即「缺失」。
- **恢复集**：容器成员级（`pub`/`fn`/`const`/`var`/`test`/`comptime`）、语句级（`;`、`}`）、表达式级（分隔符）。
- **类型化访问层**：`syntax/ast.zig`，如 `FnDecl.proto()`、`FieldAccess.lhs()`，所有访问器返回可选值；表达式统一用 `SyntaxNode`，由使用方按种类分派。
  - 作用：把「某信息位于哪个子节点」的知识集中到一处；调用方按语义访问（`proto().name()`），树结构调整时只改生成源；错用节点类型在编译期报错。
  - 手写而不是从 `grammar.zon` 生成：Zig 去掉 `usingnamespace` 后生成器能省的只是每个访问器一两行的样板，却要多维护一个工具、一个 build step 和一份语法描述（M3 决定）。
- **局部重解析**（`Parse.reparse`）：编辑落在某个 `{ ... }` 内且花括号仍平衡时，只重解析该块；否则整文件重解析。
  1. 新旧文本的公共前缀 / 后缀之外即编辑区间；在旧树中找包含它的最深 `block` / `container_decl`，要求编辑严格位于其 `{` 之后、`}` 之前，且 `}` 是该节点的最后一个 token。
  2. 对该节点的新文本单独做词法分析，校验最后一个 token 为 `}` 且花括号恰好在结尾配平；再用对应语法入口（`blockExpr` / `containerDecl`）解析，要求消费全部 token、产出单个同种类节点。任一条件不满足即回退全量解析。
  3. 只复制根到目标节点路径上的祖先，其余绿节点原样复用；节点外的旧错误保留并按长度差平移，节点内的换成新错误。
  4. 内存：新结果复用旧结果的节点，因此以引用计数持有旧结果（链式）；链上累计内存超过链底全量解析的 2 倍时改做全量解析，旧 arena 随之释放。
  5. 接入：查询引擎支持可选的 `computeIncremental(ctx, key, prev)`，重算 `ParseFile` 时传入上一次的结果。
  6. 正确性约束：增量结果必须与全量解析**完全相同**（语法树与错误逐项相等），由语料对拍中的随机编辑测试保证（§18）。

**与 `std.zig.Ast` 的关系**：只在两处使用标准库解析器——格式化（`zig fmt` 结果必须逐字一致）与 AstGen 校验（§11）。CI 用 `tests/corpus/` 对 Zig 标准库和编译器源码做对拍：两个解析器在无语法错误的文件上必须得到相同的声明结构。

### 5.2 ItemTree：文件声明骨架

```zig
pub const ItemTree = struct {
    items: []Item,                 // 树形扁平存储，含嵌套容器
    pub const Item = struct {
        name: ?NameId,             // 驻留字符串
        kind: enum { fn_decl, const_decl, var_decl, field, test_decl, comptime_block, container },
        flags: packed struct { is_pub: bool, is_extern: bool, is_export: bool, is_inline: bool, is_comptime: bool },
        parent: ?ItemIdx,
        ast_id: AstId,
        sig_hash: u64,             // 签名部分（类型注解、参数、返回类型、容器头）的结构哈希
        doc: ?TextRange,
    };
};
```

- **不含函数体与初始化表达式内容**，只有它们的存在性和 AstId。
- `item_tree(file)` 是最重要的 early cutoff 点：只改函数体时它的值不变，于是名字层与所有签名查询都不失效。
- 注意：`const S = struct {...}` 的结构体内容属于「签名」（它定义了类型），其字段与成员作为嵌套 item 进入 ItemTree。

### 5.3 AstId：稳定节点 ID

```zig
pub const AstId = struct { file: FileId, local: u32 };
```

- `local` 由「父 AstId + 节点种类 + 名字 + 同名序号」哈希/编号得到，**跨编辑稳定**（只要该声明本身没改名/没移动到别的容器下）。
- `ast_id_map(file)` query：`AstId ↔ SyntaxNodePtr(kind, range)`，每次重解析重新计算（廉价），使用者通过它把稳定 ID 换成当前树上的节点。
- 函数体内节点不分配 AstId；体内定位用 HIR 的 `ExprId` + SourceMap（§8）。

---

## 6. 查询引擎（`db/`）

### 6.1 API

```zig
pub const Db = Engine(.{
    // input
    .file_text     = Input(FileId, []const u8),
    .project_model = Input(void, ProjectModel),
    .config        = Input(void, Config),

    // syntax
    .parse         = Query(FileId, Parse, syntax.parse),                 // green tree + errors
    .item_tree     = Query(FileId, ItemTree, syntax.itemTree),
    .ast_id_map    = Query(FileId, AstIdMap, syntax.astIdMap),
    .file_index    = Query(FileId, FileIndex, ide_db.fileIndex),          // 标识符 trigram 索引

    // names
    .module_graph  = Query(void, ModuleGraph, names.moduleGraph),
    .file_modules  = Query(FileId, []ModuleId, names.fileModules),
    .namespace     = Query(ContainerId, Namespace, names.namespace),
    .resolve_import= Query(ImportKey, ?FileId, names.resolveImport),

    // hir
    .body          = Query(BodyOwner, *const Body, hir.lower),            // 含 SourceMap

    // sema
    .decl_type     = Query(DeclKey, TypedValue, sema.declType),           // 签名层：类型 / comptime 值
    .instantiate   = Query(InstKey, InstanceId, sema.instantiate),
    .infer         = Query(InferKey, *const InferResult, sema.inferBody),
    .call_eval     = Query(CallKey, EvalResult, sema.evalCall),           // comptime 函数调用记忆化
});
```

`Engine` 在 comptime 展开为每个 query 一张 memo 表，计算函数签名为 `fn (db: *Db.Ctx, key: K) Error!V`，只能经 `db.get(.query_name, key)` 读取其他 query，依赖由此自动记录。

### 6.2 Memo 与验证（红绿算法）

```zig
const Memo(V) = struct {
    value: V,
    verified_at: Revision,
    changed_at: Revision,
    durability: Durability,
    deps: []const DepKey,     // (query_tag, key_index)
};
```

`get(q, k)`：
1. 无 memo → 计算并记录。
2. `verified_at == current` → 直接返回。
3. 若 `durability` 对应层自 `verified_at` 以来无输入变化 → 标记已验证，返回。
4. 逐个 deep-verify 依赖：若所有依赖的 `changed_at <= verified_at` → 标记已验证，返回。
5. 否则重算；新值 `eql` 旧值时**保留旧 `changed_at`**（early cutoff）。

### 6.3 Key 驻留

复合 key（`InferKey`、`CallKey` 等）先驻留为 `u32`，memo 表以 `u32` 为下标，依赖边存 `(tag, u32)`，紧凑且便于比较。

### 6.4 环检测

Zig 合法地存在递归类型（`const Node = struct { next: ?*Node }`）和递归 comptime 调用。引擎维护每线程的活动查询栈：

- 遇到环 → 调用该 query 声明的 `cycle_fallback`（通常返回 `unknown` 或「惰性占位类型」），并在 memo 上标记 `in_cycle`；
- sema 层设计上保证：**容器类型的身份不依赖其字段类型**（字段解析是独立 query），因此 `*Node` 不会触发环。

**深度上限**：很长的依赖链（上千个互相引用的常量）或无限的类型构造递归会耗尽原生栈。读事务记录开始时的栈位置，嵌套计算占用的原生栈超过 4 MB 时，有 `cycle_fallback` 的 query 不再深入：返回回退值，当前栈上的 query 都标记为 `in_cycle`（结果取决于求值时的栈深度，不写入 memo）。推导器与解释器在深入表达式前同样检查。

- **迭代加深**：顶层读取因深度上限中断时，先从栈底计算中断处的 query（结果完整则写入 memo），再重新计算原来的 query。深链因此分段计算，总代价与链长成正比，结果也是完整的；每个读事务最多加深 16 次，无限递归也能结束。
- 结果已标记为不完整时（`ctx.incomplete()`），调用方不再为改进结果而深入（如 DeclType 回退到解释器），否则每一层都会重新计算。
- **燃料**：每个读事务有 comptime 求值的步数预算（默认 2000 万步），耗尽后的结果同样不写入 memo。

### 6.5 取消

- 全局 `pending_write: atomic bool`；每次 `get` 入口检查，若置位则返回 `error.Canceled` 并逐层上抛。
- 被取消的计算不写 memo。

### 6.6 内存回收

- `parse`、`body`、`infer` 设置 LRU 上限（按条数与估算字节数），淘汰仅删值、保留依赖元数据以支持后续验证后重算。
- 每次 revision 推进后，后台执行一次低优先级清扫。

### 6.7 缓存分层与持久化预留

**v1 的缓存**

| 层次 | 内容 | 存储 | 作用 |
|---|---|---|---|
| 查询 memo | 全部派生结果（解析、ItemTree、namespace、推导、comptime 求值…） | 内存 | 跨请求复用，依赖追踪 + early cutoff 实现增量 |
| Durability 分级 | std / 依赖包标记为 high | 内存 | 验证时整体跳过不变的输入，大项目收益最大 |
| ProjectModel | 构建系统协议给出的构建图 | 磁盘（§13.1） | 冷启动无需等待 `zig build` |
| 编译器缓存 | `.zig-cache` 与增量编译状态 | 磁盘（编译器自管） | 保存后快速得到编译器诊断 |

**v1 不做分析结果持久化**的原因：分析本身按需进行、解析速度足够快，冷启动的主要开销（`zig build` 配置阶段）已有磁盘缓存；而持久化需要稳定的序列化格式与可靠的失效规则，出错时表现为「重启也无法恢复」的错误结果，在引擎数据结构仍在迭代的阶段代价过高。

**为 v2 预留的约束（v1 即强制执行）**

- 每个 query 声明 `persist: bool`，标记其结果是否可持久化；可持久化的 value 类型必须实现 `serialize` / `deserialize`，CI 对其做往返一致性测试。
- 可持久化 query 的结果只能引用稳定 ID（`FileId` 经路径映射、`AstId`、`NameId`），不得引用进程内地址或 `InternPool.Index`（后者在 v2 中通过「持久化 key → 重新驻留」恢复）。
- 首批候选：std 与依赖包的 `item_tree`、`file_index`，以及 std 高频泛型的 `call_eval` 结果。
- 失效键：`hash(文件内容) + zig 版本 + zig-analyzer 版本 + 相关配置哈希`；任何一项不匹配即视为未命中，绝不尝试「部分可用」。
- 提供 `zig-analyzer/clearCache` 请求与命令行 `--clear-cache`，作为用户侧兜底。

**v2 的触发条件**：M7 实测冷启动预算未达标，或用户反馈大型工作区（> 50 万行）首次可用时间过长，则将持久化提前。

---

## 7. 名字层（`names/`）

### 7.1 模块图

- `module_graph()` 由 `project_model` 构建，附加隐式模块：`std`、`builtin`（由 `zig env` 与构建图中的模块选项生成内容，作为虚拟文件进入 Vfs）、`root`。
- 一个文件可属于多个模块（同一文件被多个 compile step 引用）。分析上下文为 `FileCtx { file: FileId, module: ModuleId }`；默认取第一个，提供自定义请求 `zig-analyzer/setActiveModule` 供客户端切换。
- 无 build.zig 或 `build.zig` 配置失败时：每个打开的文件自成模块 + std，功能降级但可用。

### 7.2 容器与命名空间

```zig
pub const ContainerId = struct { ctx: FileCtx, item: ItemIdx, inst: ?InstanceId };
```

- 文件本身是一个容器（`item = root`）。
- `inst` 区分泛型函数内部定义的容器：`fn List(comptime T: type) type { return struct {...}; }` 中，不同 `T` 产生不同 `ContainerId`——这与 Zig 语义一致。
- `namespace(container)` → 成员名 → `DeclKey` 映射，来自 ItemTree，**不依赖任何函数体**。

### 7.3 名字解析

- 容器级：在当前容器 → 外层容器链（词法嵌套）中查找。
- 函数体局部：由 HIR 的 `Scopes` 处理（§8.3），找不到再回落到容器级。
- `@import("x")`：`resolve_import(ImportKey{ctx, string})`：`.zig` 后缀走相对路径；否则查当前模块的 imports 表；`std`/`builtin`/`root` 特殊处理。

---

## 8. HIR：函数体中间表示（`hir/`）

在 CST 与 sema 之间引入一层**容错的函数体 IR**（参考 rust-analyzer 的 `Body`），而不是直接在 CST 上推导，也不使用 ZIR（ZIR 在存在语法错误时不生成，不适合编辑中的代码）。

### 8.1 BodyOwner

函数体、`const`/`var` 的初始化表达式、`comptime` 块、`test` 块、字段默认值、容器字段类型表达式，都是 `BodyOwner`（由 AstId 标识）。

### 8.2 Body

```zig
pub const Body = struct {
    exprs: std.MultiArrayList(Expr),     // ExprId = u32
    stmts: std.MultiArrayList(Stmt),
    patterns: std.MultiArrayList(Pattern), // 捕获 |x|、|*x|、|x, i|、解构
    params: []PatternId,
    root: ExprId,
    source_map: SourceMap,               // ExprId ↔ 相对 owner 的节点偏移（双向）
};

pub const Expr = union(enum) {
    missing,                              // 语法缺失处
    name_ref: NameId,
    field_access: struct { lhs: ExprId, field: ?NameId },  // `foo.` 时 field = null
    call: struct { callee: ExprId, args: []ExprId },
    builtin_call: struct { builtin: BuiltinTag, args: []ExprId },
    enum_literal: NameId,                 // `.foo`
    anon_init: struct { fields: []FieldInit },           // `.{ .a = 1 }` / `.{1, 2}`
    typed_init: struct { ty: ExprId, fields: []FieldInit },
    block: struct { label: ?NameId, stmts: []StmtId, is_comptime: bool },
    @"if": struct { cond: ExprId, capture: ?PatternId, then: ExprId, @"else": ?ExprId, else_capture: ?PatternId },
    @"switch": struct { operand: ExprId, prongs: []Prong },
    loop: struct { kind: enum { @"while", @"for" }, label: ?NameId, inputs: []ExprId, capture: []PatternId, body: ExprId, @"else": ?ExprId, is_inline: bool },
    @"try": ExprId,
    @"catch": struct { lhs: ExprId, capture: ?PatternId, rhs: ExprId },
    @"orelse": struct { lhs: ExprId, rhs: ExprId },
    // 类型表达式也是表达式（Zig 中类型是 comptime 值）
    ptr_type: PtrType, array_type: ArrayType, optional_type: ExprId, error_union_type: struct { err: ?ExprId, payload: ExprId },
    fn_proto: FnProto, container_decl: ContainerRef, error_set_decl: []NameId,
    // ... 字面量、一元/二元运算、slice、deref、address_of、return/break/continue 等
};
```

- **降级时做的规整**：`a.?` → `optional_unwrap`；`for (a, b) |x, y|` 多输入；`defer`/`errdefer` 保留为语句；`inline` 标记保留供 comptime 解释器使用。
- **嵌套容器**（体内 `struct {...}`）只记录 `ContainerRef`，内容走 ItemTree/namespace，不在 Body 内展开。

### 8.3 局部作用域

`scopes(owner)`：基于 Body 计算 `ExprId → ScopeId` 以及每个作用域的绑定（参数、局部变量、捕获、label）。补全与名字解析通过「光标所在 ExprId → 作用域链」查询可见名字。

---

## 9. 语义层（`sema/`）

### 9.1 InternPool：唯一的类型与值表示

```zig
pub const Index = enum(u32) {
    // 预置
    unknown, unknown_type, type_type, void_type, bool_type, noreturn_type, anyerror_type,
    comptime_int_type, comptime_float_type, usize_type, ...
    _,
};

pub const Key = union(enum) {
    // 类型
    int_type: struct { signedness: std.builtin.Signedness, bits: u16 },
    ptr_type: PtrInfo, array_type: ArrayInfo, vector_type: VectorInfo,
    optional_type: Index, error_union_type: struct { err: Index, payload: Index },
    error_set_type: []NameId, inferred_error_set: FnInstance,
    fn_type: FnInfo,
    container_type: ContainerId,        // 身份 = 定义位置 + 实例；字段/成员另查
    tuple_type: []Index,
    opaque_param: ParamRef,             // 未实例化泛型的符号类型参数（§9.4）
    // 值
    int_value: BigIntRef, float_value: f128, bool_value: bool,
    enum_literal: NameId, enum_value: struct { ty: Index, tag: NameId },
    slice_value, aggregate_value, ptr_value, fn_value: DeclKey, type_value: Index,
    undefined_value: Index, null_value: Index,
    unknown_value: Index,               // 类型已知、值未知
};
```

- 分片 + 读多写少锁（或每分片自旋锁），只追加不删除；随引擎 revision 不回收（类型身份需稳定）。v2 再考虑代际回收。
- 容器字段与成员类型通过独立 query `container_fields(ContainerId)` 获得，保证容器身份与字段解析解耦，天然支持递归类型。

### 9.2 三类核心 query

| Query | 输入 | 输出 | 依赖范围 |
|---|---|---|---|
| `decl_type(DeclKey)` | 声明的签名部分 | 声明的类型；对 `const` 若可 comptime 求值则附带值 | ItemTree、namespace、其他 decl_type、call_eval |
| `infer(InferKey)` | `BodyOwner` + `InstanceId?` | `ExprId → TypedValue`、`ExprId → 解析目标` | body、scopes、decl_type、call_eval |
| `call_eval(CallKey)` | comptime 调用 `(fn, comptime 实参)` | 返回值（常见：返回一个 `type`） | infer（以该实例） |

**签名/函数体隔离**：`decl_type` 不读取任何函数体（返回类型为 `type` 的泛型函数除外，它通过 `call_eval` 按实例求值，结果按实例缓存）。

### 9.3 推导算法

双向类型检查，对应 Zig 的「结果类型」语义：

```zig
fn infer(expr: ExprId, expected: Expected) TypedValue
// Expected = none | ty(Index) | coerce_to(Index)
```

- `.foo`、`.{...}`、`@intCast`、`@as`、`@enumFromInt` 等依赖期望类型；赋值、参数传递、返回值、字段初始化、`switch` prong 均下推期望类型。
- 二元运算与 `if`/`switch` 分支汇合做 **peer type resolution**（按语言规范实现子集：整数提升、optional/error union 包裹、指针 const 合并）。
- `unknown` 吸收一切：任何参与 `unknown` 的运算结果为 `unknown`，**不产生诊断**。

### 9.4 泛型与 comptime

**核心思路：用真正的 comptime 求值替代启发式。**

1. **comptime 解释器（`eval.zig`）**
   - 在 HIR 上解释执行。离开解释器的值（返回值、实参、query 结果）是 InternPool `Index`；解释器内的值可以修改（局部变量、数组与结构体元素、经由指针写入，指针表示为存储单元 + 元素路径），只在离开时驻留，避免只增不减的 InternPool 堆积中间结果。
   - 支持：算术/位运算/比较（按类型位宽回绕、饱和、溢出检查；浮点以 f128 计算并按类型精度舍入）、`if`/`switch`（含范围、带标签的 `continue`）/`while`/`for`（含 `inline`、指针捕获、`else`）、块与 label、`defer`、函数调用（经 `call_eval` 记忆化）、容器与元组 / 匿名结构体构造、`@typeInfo` 与 `@Enum`/`@Struct`/`@Union`/`@Tuple`/`@Pointer`/`@Fn`/`@Int`/`@Vector`、`@field`/`@hasField`/`@hasDecl`/`@FieldType`/`@TypeOf`/`@This`/`@tagName`、切片与数组字面量、错误与 optional。
   - **燃料**：单次求值 20 万步、内存 64 MB、单个聚合 65536 个元素、解释器内嵌套调用 64 层；每个读事务另有总步数预算（§6.4）。超出时放弃求值，结果为 `unknown`。
   - 遇到运行时值、外部函数、`@cImport`、内联汇编、`@compileError` → `unknown`，不报错。
   - 三值格：`known(value)` / `typed_unknown(type)` / `unknown`。
   - **与推导器的分工**：推导器给出每个表达式的类型（IDE 使用）；在 comptime 上下文中（类型标注、参数与返回类型、数组长度、comptime 实参）求不出值时交给解释器；容器级常量的值、返回 comptime-only 类型（`type`、含 `type` 字段的结构体等）的调用由解释器求出。
   - **`call_eval`（`CallEval` query）**：键为「实例 + 各参数的值」。实例与类型推导中相同（comptime 参数取值并按实例中的参数类型转换，anytype 取类型，其他为 `runtime` 占位），保证两边得到的容器身份一致；运行时参数的值另存于键中。

2. **类型构造函数**：`fn ArrayList(comptime T: type) type` 在 `decl_type` 遇到 `ArrayList(u8)` 时，经 `call_eval` 求值得到 `container_type{ item: <struct>, inst: Inst(ArrayList, [u8]) }`。std 的大部分泛型容器、`std.meta`、`std.enums` 因此无需特判即可工作。

3. **泛型函数体（无具体实例时）**：
   - 以「抽象实例」推导：`comptime T: type`（含不写 comptime 的 `T: type`）绑定为 `opaque_param(T)`；`anytype` 参数类型未知；
   - 对 `opaque_param` 的成员访问 → `unknown`；hover 显示为 `T`；取决于抽象参数的比较（`[2]T == [2]u8`）为未知，不选择分支；
   - 类型相等：同一位置、不同实例的容器按它捕获的外层参数与局部变量的值判断（不捕获实参的容器在不同实例间是同一个类型）；
   - **调用点种子**（默认开启）：取第一个能求出具体实例的调用点做推导，hover 标注「inferred from the call at file.zig:123」。结果按实例缓存，可解释、可复现。先在同一文件中查找，再经 `file_index` 在能引用到该函数的其他项目文件中查找（M6）。

4. **inferred error set**：`!T` 的错误集由函数体推导，按需计算；签名层只记录「inferred」标记（`inferred_error_set` 类型，不读取函数体），成员由 `ErrorSetOf` query 收集函数体中 `return` 的错误与 `try` 传播的错误；含未知部分或参与递归时为 `anyerror`。

### 9.5 Builtin

- `tools/gen_builtins.zig` 从 `builtins.zon`（名称、参数、文档、签名片段）生成数据表，供补全/签名帮助/hover 使用。
- 返回类型规则在 `sema/builtins.zig` 中逐个实现（`@TypeOf`、`@This`、`@field`、`@typeInfo` 等语义依赖解释器）。
- 文档内容随 Zig 版本更新，与代码分离维护。

---

## 10. 语义门面与 IDE 层

### 10.1 Semantics API（`semantics/`）

IDE 层**只能**通过这一层访问语义，不直接调 query：

```zig
pub const Semantics = struct {
    snap: *const Snapshot,

    pub fn typeOf(s: Semantics, node: SyntaxNode) ?TypeRef;
    pub fn resolve(s: Semantics, name_ref: SyntaxNode) ?Definition;     // decl / local / field / param / label / module
    pub fn scopeAt(s: Semantics, file: FileId, offset: u32) ScopeView;   // 可见名字迭代
    pub fn members(s: Semantics, ty: TypeRef) MemberIter;                // 字段 + decl + 方法（含 *Self 推导）
    pub fn expectedTypeAt(s: Semantics, node: SyntaxNode) ?TypeRef;     // 用于 `.foo` / `.{}` 补全
    pub fn callInfo(s: Semantics, call: SyntaxNode) ?CallInfo;           // signature help / inlay hints
    pub fn instanceNote(s: Semantics, node: SyntaxNode) ?InstanceNote;   // 泛型推导来源
};
```

CST 节点 → 所属 `BodyOwner` → `SourceMap` → `ExprId` → `infer` 结果，全部封装在门面内。

### 10.2 ide_db

- `file_index(file)`：精确名字表 + `@import` 字符串，用于引用候选、调用点种子（trigram 暂未实现，见 §19.6）。
- `search.find_refs(def)`：按名字在索引中粗筛文件 → 对候选位置 `resolve` 精确确认；可按作用域裁剪（局部变量只搜当前 body）。
- `render.type(ty)`：统一的类型展示（hover、inlay hint、补全 detail 共用），控制截断与泛型参数显示。
- `edits`：基于 CST 的编辑构造器，保留 trivia。

### 10.3 功能清单

| 功能 | 依赖层 | 备注 |
|---|---|---|
| semantic tokens / folding / selection range / document symbol | syntax | 纯语法，最先交付 |
| formatting | `std.zig.Ast.render` | 与 `zig fmt` 逐字一致，输出最小 diff |
| goto definition / declaration / type definition | semantics | 支持 import 字符串跳转到文件 |
| hover | semantics + render | 类型、值（comptime 已知时）、文档、泛型来源 |
| completion | semantics | 成员、作用域名字、期望类型驱动的 `.enum` / `.{ .field }`、builtin、import 路径、label |
| signature help / inlay hints | semantics | 参数名、推导类型 |
| references / document highlight / rename | ide_db.search | rename 前做 prepareRename 校验 |
| workspace symbol | file_index | 后台建索引，带进度 |
| code actions | semantics + edits | 丢弃未使用参数、补全 switch 分支、填充结构体字段、提取变量等 |

---

## 11. 诊断（`diagnostics/`）

### 11.1 「100% 一致」的定义

对于**同一份磁盘内容、同一 Zig 版本、同一构建 step 与构建参数**，zig-analyzer 发布的诊断集合与 `zig build <step>` 的输出逐条相等：

- 文件、起止位置（ErrorBundle 中的 span start / main / end 字节偏移）完全一致；
- 严重级别、错误文案逐字一致（不改写、不翻译、不截断）；
- note 与 reference trace 一一对应（映射为 LSP `relatedInformation`）；
- 不额外报告编译器不会报告的错误（例如未被分析的泛型函数体中的错误、不在编译集合中的文件），也不遗漏编译器会报告的错误（包括链接错误）。

为此，诊断**只**有两个来源，且两者都直接运行 Zig 官方代码：

| 来源 | 触发 | 实现 | 覆盖 |
|---|---|---|---|
| `live` | 每次编辑（防抖 ~50ms） | 进程内 `std.zig.Ast.parse` → 无解析错误时 `std.zig.AstGen.generate`，产出 `ErrorBundle` | 解析错误 + AstGen 错误（未使用变量、遮蔽、未定义标签等） |
| `compiler` | 保存后由 watch 进程自动重编译 | 编译器进程经 `std.zig.Server` 协议回传 `ErrorBundle` | 全部错误：解析、AstGen、Sema、codegen、链接 |

自研 CST 解析器的错误、`sema/` 的推导结果**不参与**诊断。

### 11.2 `live` 来源：官方解析器 + AstGen

- 解析错误使用 `std.zig.Ast` 的错误而非自研 CST 的错误，保证文案与位置与编译器相同。
- **版本一致性**：进程内 AstGen 的代码来自 zig-analyzer 编译时链接的标准库。
  - 用户 zig 版本 == 内置标准库版本 → 进程内执行（快路径）；
  - 不一致 → 改为调用用户的 `zig ast-check --color off`（未保存内容经 stdin 传入），解析其输出构造 ErrorBundle（慢路径，仍保证一致）。
- `.zon` 文件同理，使用 `ZonGen` / `zig ast-check --zon`。
- **只对编译集合内的文件生效**（见 §11.4）：编译器只会对被 import 图覆盖的文件做 AstGen，集合外的文件不发布 `live` 诊断。

### 11.3 `compiler` 来源：编译器进程

**有 `build.zig` 的项目**

- 通过官方构建系统协议常驻 `zig build --listen=-`（§13），用 `bsp_build_steps` 请求构建所选 step；每个 step 完成时编译器回传 `bsp_step_completed`，其中直接携带该 step 的 `ErrorBundle`。
- 保存后由 maker 进程自身的文件监听（握手中 `file_system_watch_supported`）或我们主动再次请求触发重编译；`-fincremental` 作为构建参数透传。
- 默认 step：项目存在 `check` step 则用 `check`，否则用默认 `install` step；可配置为多个 step，结果按 (文件, span, 文案) 去重合并。
- 构建参数（`-Dtarget`、`-Doptimize` 等）由配置指定，与用户命令行保持一致是「一致性」的前提，需在文档中明确告知用户。

**无 `build.zig` 的单文件**

- 直接以 `zig build-obj <file> -fno-emit-bin --listen=-` 启动编译器服务模式，保存后发送 `update` 消息，接收 `ErrorBundle`。
- 一致性基准对应为 `zig build-obj -fno-emit-bin <file>`。

**`build.zig` 本身有错**：协议回传 `bsp_configuration_failed` 及其 `ErrorBundle`，作为 `build.zig` 的 `compiler` 诊断发布，与 `zig build` 行为一致。

### 11.4 编译集合

- 编译器只对从模块根文件出发、沿 `@import` 可达的文件做 AstGen（AstGen 阶段即会收集全部 import，与 Sema 是否分析到无关）。
- `compile_set` query：从 `project_model` 中所选 step 的根模块出发，基于 ItemTree 中的 import 列表计算可达文件集合。
- 每次编译完成后，以编译器回报的文件列表校正 `compile_set`（以编译器为准，自算结果只用于两次编译之间的 `live` 来源）。
- 集合外的已打开文件：不发布诊断；在状态栏（`zig-analyzer/status` 通知）提示「该文件不在任何编译单元中」。

### 11.5 已保存内容与未保存内容

编译器只读取磁盘，因此 `compiler` 来源描述的是**最近一次保存并编译的内容**。

| 文件状态 | 发布的诊断 |
|---|---|
| 缓冲区 == 最近编译的内容 | 仅 `compiler` 来源（它已包含该文件的解析 / AstGen 错误） |
| 缓冲区有未保存修改 | `live`（基于当前缓冲区）+ `compiler` 中的非解析 / 非 AstGen 错误（基于已保存内容，位置经 `remap.zig` 按编辑增量平移） |
| 编译进行中 | 保留上一轮结果，编译完成后原子替换 |

- **位置平移**：记录自最近一次编译以来的全部 `didChange` 增量，将旧 span 映射到当前缓冲区；span 落在被修改区域内的错误无法可靠映射，按配置 `diagnostics.stale_in_edited` 处理（默认隐藏，保存后由新编译结果恢复）。
- 诊断的 `source` 字段区分 `zig`（编译器）与 `zig ast-check`（live），便于用户辨别。
- 编译状态（编译中 / 成功 / 失败 / 被取消）通过 `$/progress` 通知客户端。

### 11.6 发布

- `Collector` 按 `(source, file)` 存储，按 §11.5 规则合并后推送；每轮编译结果携带构建序号，乱序到达的旧结果直接丢弃。
- 同时支持 push（`textDocument/publishDiagnostics`）与 pull（`textDocument/diagnostic`、`workspace/diagnostic`），按客户端能力选择。
- 依赖编译器诊断的 code action（如「丢弃未使用的参数」「移除未使用的变量」）以诊断的 span 为锚点生成编辑。

---

## 12. 服务器与并发（`server/`）

### 12.1 主循环

```
reader 线程: 读 JSON-RPC → 解析 → 投递到 scheduler

scheduler:
  写消息（didOpen/didChange/didClose/didSave/配置/工作区/watch 事件）:
      engine.requestWrite()          // 置 pending_write，进行中的读查询陆续 Canceled
      await 读者归零（毫秒级）
      应用输入变更，revision++
      清 pending_write
      安排诊断任务（防抖）
  读请求:
      snap = engine.snapshot()        // 持有读锁，revision 固定
      io.async(handler, snap, req)
  $/cancelRequest:
      置该请求的取消标志
```

- 被取消的读请求回复 `ContentModified`（-32801），客户端会自动重试。
- **请求优先级**：completion / hover / signature help > 诊断 > 索引构建；后台任务在交互请求到达时让步。
- 需要「写后立即读」的请求（如 `willSaveWaitUntil`、formatting）按顺序在写之后执行。

### 12.2 LSP 协议层（`lsp/`）

- `tools/gen_lsp_types.zig` 从官方 `metaModel.json` 生成全部类型与方法表，避免手写和第三方依赖。
- 传输：stdio（默认）；保留 socket 传输供调试。
- 位置编码：协商 `positionEncoding`，优先 UTF-8，回落 UTF-16；行索引作为 `line_index(file)` query 缓存。

### 12.3 自定义请求

| 方法 | 用途 |
|---|---|
| `zig-analyzer/status` | 引擎统计：memo 数、命中率、内存、慢查询 Top N |
| `zig-analyzer/setActiveModule` | 多模块文件切换分析上下文 |
| `zig-analyzer/syntaxTree` | 调试：打印 CST |
| `zig-analyzer/hir` | 调试：打印函数体 HIR 与推导结果 |
| `zig-analyzer/reloadProject` | 手动重启构建系统协议进程并重新获取构建图 |
| `zig-analyzer/clearCache` | 清除 zig-analyzer 自身的磁盘缓存（ProjectModel 等） |

---

## 13. 构建集成（`project/`）

### 13.1 构建系统协议（BSP）

Zig 0.17 的 `zig build` 拆分为 configurer（执行 `build.zig` 得到构建图）与 maker（执行构建）两个进程，并提供面向 IDE 的官方构建系统协议 `zig build --listen=-`（消息格式为 `std.zig.Server` / `std.zig.Client`）。zig-analyzer 直接作为该协议的客户端，**不再维护自定义 build runner**。

| 消息 | 方向 | 用途 |
|---|---|---|
| `bsp_handshake` | maker → 我们 | 协议版本（`build_system_version`）、是否支持文件监听 |
| `bsp_configuration` | maker → 我们 | 构建图文件路径；用 `std.Build.Configuration.loadFile` 读取，得到全部 step、模块（`root_source_file`、`import_table`）、目标与选项 → 转换为 `ProjectModel` |
| `bsp_configuration_failed` | maker → 我们 | `build.zig` 自身的编译错误（`ErrorBundle`） |
| `bsp_build_steps` | 我们 → maker | 请求构建指定 step |
| `bsp_build_started` / `bsp_step_started` / `bsp_build_completed` | maker → 我们 | 进度（映射为 LSP `$/progress`） |
| `bsp_step_completed` | maker → 我们 | step 结果与 `ErrorBundle`（§11.3） |

- **版本耦合**：`Configuration` 的二进制格式由标准库定义，zig-analyzer 编译时所用的标准库必须与用户 zig 的 `build_system_version` 一致；不一致时提示用户使用匹配版本的 zig-analyzer，并降级为单文件模式。这与「zig-analyzer 版本跟随 Zig 版本」的发布策略（§17）一致。
- `ProjectModel` 按 `hash(build.zig, build.zig.zon, zig 版本)` 缓存到用户缓存目录，冷启动直接加载，后台再刷新。
- configurer 的配置缓存由 Zig 自身管理（缓存污染追踪），`build.zig` 未变化时重新获取构建图很快。
- 构建图中的 `LazyPath` 若指向生成文件（如 `addWriteFiles` 产物），在对应 step 构建完成后由 `bsp_step_completed` 的生成文件列表解析出真实路径。

### 13.2 协议进程生命周期

- 项目打开时启动；崩溃后指数退避重启并上报。
- `build.zig` / `build.zig.zon` 变化时，maker 自动重新配置并推送新的 `bsp_configuration`；完成前继续使用旧模型。
- 同一进程同时承担项目模型获取与编译器诊断（§11.3），不需要额外的 watch 进程。

---

## 14. 可观测性

- **tracy**：编译期开关，query 粒度 zone，自动以 query 名标注。
- **query 统计**：每个 query 的执行次数、命中率、累计耗时、cutoff 次数，经 `zig-analyzer/status` 暴露。
- **慢请求日志**：超过阈值的请求记录完整 query 调用树。
- **日志**：`window/logMessage` + 可选文件日志，按模块分级。

---

## 15. 配置

配置来源按优先级从低到高合并：内置默认值 → 全局配置文件 → 项目 `zig-analyzer.json` → 客户端 `workspace/configuration`。合并结果作为 `config` input 进入引擎，变更只让依赖相关配置项的 query 失效。

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `zig.path` | 自动探测 `PATH` | zig 可执行文件路径 |
| `build.enable` | `true` | 是否通过构建系统协议获取项目模型 |
| `build.args` | `[]` | 传给 `zig build` 的额外参数（如 `-Dtarget=...`） |
| `diagnostics.compiler` | `true` | 是否运行编译器 watch 进程 |
| `diagnostics.steps` | `[]`（自动：`check` 否则 `install`） | 用于诊断的构建 step 列表 |
| `diagnostics.incremental` | `true` | 是否传 `-fincremental` |
| `diagnostics.stale_in_edited` | `"hide"` | 被修改区域内的旧编译错误：`hide` / `keep` |
| `inlay_hints.types` / `.parameters` | `true` | 类型提示 / 参数名提示 |
| `inlay_hints.hide_redundant_param_names` | `true` | 实参名与形参名相同时不显示 |
| `completion.snippets` | `true` | 函数调用补全是否带参数占位 |
| `sema.callsite_seeding` | `true` | 泛型函数体是否用调用点实例推导 |
| `sema.comptime_fuel` | `100000` | 单次 comptime 调用的步数上限 |
| `cache.max_memory_mb` | `1024` | LRU 回收触发阈值 |
| `log.level` / `log.file` | `info` / 无 | 日志级别与文件 |

- 配置 schema 由 `tools/gen_config.zig` 从 `config.zon` 单一来源生成：Zig 结构体、JSON Schema、文档表格，三者不会不一致。
- 未知配置项记录警告但不报错；类型错误的配置项回落到默认值并通过 `window/showMessage` 提示一次。

---

## 16. 工程约定

### 16.1 错误处理

- 引擎内只允许三类错误向上传播：`error.Canceled`、`error.OutOfMemory`、`error.Cycle`（由引擎转换为 fallback 值，不会到达 IDE 层）。
- **用户代码的任何问题都不是错误**：语法错误、无法解析的名字、求值失败一律表示为数据（`ERROR` 节点、`unknown`），且不转化为诊断。
- IDE 层 handler 捕获其他意外错误，回复 `InternalError` 并记录完整 query 调用栈，进程不退出。
- 禁止在分析路径中 `panic`/`unreachable` 处理用户输入相关的分支；断言只用于内部不变式，Debug/ReleaseSafe 下生效。

### 16.2 内存

| 生命周期 | 分配方式 |
|---|---|
| 单次请求的临时数据 | 请求级 arena，请求结束整体释放 |
| query 结果 | 每个 memo 独立 arena（或按 query 类型的 slab），随 memo 淘汰释放 |
| InternPool | 全局分片的追加式存储 |
| 绿树节点 | 每次解析一个 arena，文件的 `parse` memo 淘汰时释放 |

- query 结果必须是**自包含的不可变值**，不得持有指向其他 memo 内部的指针（只能存 ID），保证 memo 可以独立淘汰。
- 所有字符串名字经 `NameId` 驻留，结构中只存 `u32`。

### 16.3 代码规范

- 一个 query 一个函数，函数顶部注释说明：key、value、依赖哪些 query、是否为 cutoff 点。
- `ide/` 下的模块禁止 import `db/`、`sema/`、`hir/`，只能经 `semantics/` 与 `ide_db/`（CI 中用脚本检查 import 关系）。
- 生成代码（`lsp/types.zig`、`syntax/ast.zig`、配置、builtin 数据）提交到仓库，CI 校验与生成器输出一致。

---

## 17. 分发与发布

- **版本号**：跟随 Zig 版本主线，`zig-analyzer 0.17.x` 支持 Zig `0.17.x`；nightly 构建对应 Zig master。
- **产物**：`x86_64`/`aarch64` × `linux`/`macos`/`windows` 静态二进制，CI 交叉编译；附带 SHA256 与签名。
- **版本选择**：编辑器插件根据项目 `build.zig.zon` 的 `minimum_zig_version` 或 `zig version` 选择匹配的 zig-analyzer 版本并自动下载。
- **编辑器支持**：官方维护 VS Code 扩展；Neovim（nvim-lspconfig）、Helix、Zed、Emacs 通过标准 LSP 配置接入，仓库提供各编辑器配置示例。
- **发布节奏**：nightly 每日自动发布；release 在 Zig 正式版发布后 2 周内跟进。

---

## 18. 测试策略

### 18.1 Fixture 格式（多文件 + 标记）

```zig
//- /build.zig.model   modules: main=/src/main.zig, foo=/lib/foo.zig
//- /src/main.zig
const foo = @import("foo");
pub fn main() void {
    const list = foo.make();
    list.<|>
//        ^ completion: items, append, deinit
}
//- /lib/foo.zig
pub fn make() std.ArrayList(u8) { ... }
```

- `<|>` 光标、`^ assertion` 断言行、`//- path` 文件分隔；同一格式用于 sema / ide / incremental 测试。
- 类型断言：`const x = expr; // ^ type: []const u8`。

### 18.2 测试类别

| 类别 | 内容 |
|---|---|
| `syntax/` | 解析快照（CST dump）；错误恢复用例 |
| `corpus/` | 对 Zig std 与编译器源码：不崩溃、与 `std.zig.Ast` 声明结构对拍 |
| `sema/` | 类型推导断言，覆盖泛型、comptime、peer type、结果类型 |
| `ide/` | 各功能快照测试 |
| `incremental/` | 编辑序列：增量结果 ≡ 从零计算结果；断言指定 query **未被重算**（验证 cutoff） |
| 模糊 / 性质测试 | 每个性质写成以字节流为熵的函数，两种驱动方式共用：固定种子的伪随机循环（每次 `zig build test` 在所有平台运行，Debug 下取十分之一迭代）与 `std.testing.fuzz`（`zig build test --fuzz=<次数>` 覆盖率引导）。现有性质：URI ↔ 路径往返（posix / windows 两种风格在所有平台都测）、任意输入不崩溃、路径规范化幂等与盘符大小写统一；解析器任意输入无损、随机编辑下增量与全量一致；位置换算与增量变更 |
| `bench/` | 冷启动各阶段耗时（§1 冷启动预算）、典型请求延迟、内存，CI 中跟踪回归 |
| 分配失败 | 用失败分配器跑全部测试，验证 OOM 路径 |
| `diagnostics/` | **一致性对拍**：错误样例语料（解析、AstGen、Sema、链接、多 step、无 build.zig、`.zon`）上，LSP 发布结果与 `zig build` 的 ErrorBundle 逐条比较（文件、span、级别、文案、note）；覆盖快路径与 `ast-check` 慢路径；位置平移用随机编辑序列测试 |

---

## 19. 里程碑

| 阶段 | 状态 | 交付 | 验收标准 |
|---|---|---|---|
| **M0 基础** | ✅ 已完成 | `db/` 引擎、Vfs、`lsp/` 代码生成、Server 骨架、取消机制 | 引擎单测：增量、cutoff、环、取消；能与编辑器握手 |
| **M1 语法** | ✅ 已完成 | CST 解析器、ItemTree、AstId、语法类功能、formatting、`live` 诊断 | corpus 对拍通过；语法功能日常可用 |
| **M2 构建与诊断** | ✅ 已完成 | 构建系统协议客户端 + ProjectModel、编译器 watch 进程、编译集合、未保存内容的位置平移、诊断发布 | 诊断一致性对拍 100% 通过 |
| **M3 名字** | ✅ 已完成 | 类型化 AST 访问层生成（§5.1，先于 HIR）、模块图、namespace、import 解析、HIR 降级、局部作用域 | goto definition 跨文件/跨模块/进 std 可用；名字补全可用 |
| **M4 类型** | ✅ 已完成 | InternPool、`decl_type`、`infer` 双向推导、peer type、hover/补全/inlay hints/signature help | sema 测试集覆盖语言主要特性；在 std 上 hover 抽查准确率达标 |
| **M5 comptime** | ✅ 已完成（见 §19.8） | 解释器、`call_eval`、类型构造函数、`@typeInfo`/`@Type`、泛型抽象实例 + 调用点种子 | `std.ArrayList`/`HashMap`/`MultiArrayList`/`std.meta` 系列推导正确 |
| **M6 引用** | ✅ 已完成（见 §19.12） | file_index、references、rename、document highlight、workspace symbol、code actions、跨文件的调用点种子（§9.4） | rename 在大项目上正确且 < 1s |
| **M7 性能** | ✅ 已完成（见 §19.13；两项预算受上游限制） | 性能调优、内存回收、增量编译诊断延迟优化、冷启动优化 | 在 Zig 编译器源码上达到 §1 热状态与冷启动预算；未达标则评估将 §6.7 持久化提前 |
| **v1.0** | ⏳ 下一步 | 稳定性、文档、发布流程 | — |

### 19.1 M0 完成情况（2026-10-12）

| 模块 | 文件 | 内容 |
|---|---|---|
| 查询引擎 | `src/db/engine.zig` | input / derived query、红绿验证与 early cutoff、durability、读写事务与取消、环检测与 `cycleFallback`、旧值延迟释放 |
| LSP 类型 | `tools/gen_lsp_types.zig` → `src/lsp/types.zig` | 由 `zig build gen` 从 `tools/metaModel.json`（LSP 3.18）生成；联合类型按 JSON 形状匹配、字符串字面量校验、递归类型自动用指针 |
| 协议层 | `src/lsp/jsonrpc.zig`、`src/lsp/transport.zig`、`src/lsp/json_ext.zig` | 消息分类解析与构造、Content-Length 分帧、线程安全写出 |
| 基础层 | `src/base/`、`src/util/offsets.zig` | Vfs 路径驻留、file URI 互转（含 Windows）、`FileText` input、UTF-8/16/32 位置换算与增量变更 |
| Server | `src/server/Server.zig`、`src/main.zig` | 写消息串行、读请求并发；`ContentModified` / `RequestCancelled`；`initialize`（协商位置编码）、`shutdown`、`exit`、文档同步、`zig-analyzer/status` |

- 测试：`zig build test` 共 37 个，覆盖引擎（含跨线程取消与并发读）、JSON 往返、Server 生命周期与错误码。
- 与设计的差异：查询引擎合并为单文件 `db/engine.zig`；Server 的调度与 handler 暂在同一文件中。
- CI 已补充，见 §19.3。
- 实施中的设计修正：构建集成改用 Zig 0.17 官方构建系统协议（§13），不再维护自定义 build runner。

### 19.2 M1 完成情况（2026-10-12）

| 模块 | 文件 | 内容 |
|---|---|---|
| 词法 | `src/syntax/lexer.zig`、`kind.zig` | 复用 `std.zig.Tokenizer` 保证 token 语义与编译器一致，token 间隙切分为 trivia，做到无损 |
| 解析器 | `src/syntax/parser.zig`、`grammar.zig`、`green.zig`、`tree.zig`、`Parse.zig` | 事件式递归下降（Marker / `precede`），决策与 `std.zig.Parse` 对应；容器成员、语句、参数 / 参数列表 / 初始化列表等多级恢复；红绿树、按偏移定位、覆盖路径 |
| ItemTree | `src/syntax/ItemTree.zig` | 声明骨架（含函数体内的容器）、签名哈希、文档文本；基于（父 ID, 种类, 名字, 序号）的稳定 AstId 与 AstIdMap |
| query | `src/syntax/queries.zig`、`src/diagnostics/live.zig` | `ParseFile`、`FileItemTree`（cutoff 点）、`FileAstIdMap`、`AstCheck` |
| 功能 | `src/ide/` | documentSymbol、foldingRange、selectionRange、semanticTokens/full（纯语法分类）、formatting（`std.zig.Ast.render`，按行最小替换） |
| live 诊断 | `src/diagnostics/live.zig`、Server | 进程内 `Ast.parse` + `AstGen` / `ZonGen`，打开与修改后异步推送 `publishDiagnostics`，被后续编辑取消 |
| 语料对拍 | `tools/corpus.zig`（`zig build corpus -- <目录>`） | 无损、零误报、逐容器成员结构与 `std.zig.Ast` 一致、截断健壮性、ItemTree 映射 |

- 语料结果：`lib/zig` 全部 + ZLS 源码共 1013 个文件（28 MB）：无损失败 0、误报 0、结构不一致 0，7091 次截断解析无崩溃；CST 解析约 90 MB/s，ItemTree 12.9 万个成员全部正确映射。
- 实测（`std/zig/AstGen.zig`，554 KB / 1.37 万行）：首次 documentSymbol 22 ms、缓存命中 1.7 ms、编辑后 10 ms；semanticTokens 21 ms；formatting 8 ms。
- 测试：`zig build test` 共 67 个，包括 ItemTree 的 early cutoff 断言（只改函数体时下游 query 不重算）与 live 诊断（预期值取自 `zig ast-check` 实际输出）。
- 与设计的差异：
  - 词法层复用 `std.zig.Tokenizer`，只自研解析器部分（§5.1）。
  - 类型化 AST 访问层（`gen_syntax.zig` + `grammar.zon`）延后到 M3、HIR 降级之前生成（§5.1）。当前用到语法树的只有 ItemTree 与 5 个语法功能，访问模式尚少，过早设计生成器容易生成用不上的接口；现阶段功能代码直接使用 `SyntaxNode.childNode / childToken`，生成后统一迁移。
  - 局部重解析已实现（§5.1）：语料上 11208 次随机编辑（含连续编辑形成的复用链）中 5600 次走局部重解析，与全量解析的不一致为 0；走局部重解析的编辑平均比全量快 6.2 倍。实测在 554 KB 文件的函数体内逐字输入时，ItemTree 因 cutoff 不再重算，单次编辑后请求约 8 ms，主要耗时已不在解析（全量约 5.6 ms，局部 < 1 ms），而在功能计算、行索引、JSON 序列化与同时运行的 AstGen。
  - 已知问题：live 诊断的 AstGen 是标准库代码，计算过程中不检查取消，写事务需要等它结束；大文件上会增加编辑延迟，后续考虑防抖或把 AstGen 放到单独的计算队列。
  - ItemTree 存文档文本而非文档位置（位置会随编辑平移、破坏 cutoff），并收录函数体内定义的容器（名字解析需要其成员）。
  - 查询引擎增加只读环境参数 `Env`（当前为 `*Vfs`），供 query 获取不变的文件路径信息。
- 留到 M2：live 诊断的编译集合限制（§11.4）、内置标准库与用户 zig 版本不一致时回退 `zig ast-check`（§11.2，依赖 `zig env`）。

### 19.3 CI 与模糊测试（2026-10-12）

- `.github/workflows/ci.yml`：
  - **测试**（ubuntu / macos / windows）：Debug 与 ReleaseSafe 两遍 `zig build test`、构建可执行文件、语料对拍（当前 Zig 标准库 + 本仓库源码）；
  - **格式与生成代码**（ubuntu）：`zig fmt --check`；`zig build gen` 后 `types.zig` 必须与提交一致；
  - **覆盖率引导模糊测试**（ubuntu）：`zig build test -Doptimize=ReleaseSafe --fuzz=50K`（每个模糊目标 5 万次）。必须用优化构建：Linux x86_64 的 Debug 构建默认走 Zig 自研后端，不支持覆盖率插桩（覆盖率文件 `pcs_len` 为 0）；ReleaseSafe 走 LLVM，吞吐量也比 Debug 高一个数量级。本地可加大次数做长时间模糊测试，覆盖率数据保存在 `.zig-cache` 中跨次累积。
- `.gitattributes` 统一 LF，避免 Windows 检出后格式与生成代码校验误报。
- `zig build corpus` 默认校验当前 Zig 的标准库（由 `build.zig` 传入路径），可追加目录。
- 路径处理（`base/uri.zig`、`Vfs.normalize`）改为显式的 posix / windows 风格参数，两种规则在任何平台都能测试。模糊测试发现并修复：URI 中原始控制字符（含 NUL）未被拒绝；UNC 主机名含路径分隔符时拼出非法路径。同时补充 UNC（`file://server/share/x` ↔ `\\server\share\x`）、`%00` 拒绝、Windows 盘符统一大写。
- 大小写不敏感的文件系统：Vfs 的文件身份键在 Windows / macOS（默认）上统一 ASCII 字母大小写，`C:\Work\A.zig` 与 `c:/work/a.zig` 是同一个 FileId；对外（显示、构造 URI）保留第一次见到的写法。采用纯字符串处理而非查询磁盘真实大小写，因为编辑器中新建未保存的文件在磁盘上不存在。路径风格与大小写模式都是 Vfs 的参数，测试在所有平台覆盖四种组合，模糊测试随机翻转字母大小写验证身份判定。
- 已知限制：只统一 ASCII 字母；NTFS 的 Unicode 大写映射、APFS 对 Unicode 规范化形式（组合 / 分解）不敏感的行为未处理，需要 Unicode 数据表。大小写模式按平台默认，尚未开放配置（macOS 可格式化为大小写敏感卷，Linux ext4 可对目录开启不敏感）。

---

### 19.4 M2 完成情况（2026-10-12）

| 模块 | 文件 | 内容 |
|---|---|---|
| zig 环境 | `src/project/ZigEnv.zig` | 运行 `zig env` 获取 zig 路径、标准库、缓存目录与版本；与编译时版本比较 |
| 构建系统协议 | `src/project/bsp.zig` | `zig build --listen=-` 客户端：消息编解码、ErrorBundle 解码、构建请求；单文件模式 `zig build-obj -fno-emit-bin --listen=-` |
| 项目模型 | `src/base/ProjectModel.zig`、`src/project/configuration.zig` | 从 `std.Build.Configuration` 提取 step、依赖、模块、根文件（LazyPath 解析为绝对路径）与 import 表 |
| 编译集合 | `src/diagnostics/compile_set.zig` | 每个 compile step 从根模块与 `std.zig` 出发，沿 ZIR 的 import 列表遍历；缺失文件从磁盘加载后重算（std 为 high durability） |
| 编译器诊断 | `src/diagnostics/compiler.zig` | ErrorBundle → 按文件的诊断（以构建完成时的磁盘文本为基准，标记 AstGen 错误）；按 §11.5 与 live 诊断合并，未保存修改时按文本差异平移、修改区域内隐藏 |
| live 诊断 | `src/diagnostics/live.zig` | 同一查询产出诊断与 ZIR import 列表；`LiveBackend` input 决定进程内 AstGen 或 `zig ast-check` 子进程（版本不一致时） |
| 项目管理 | `src/server/Workspace.zig`、Server | 每个带 build.zig 的工作区一个后台任务；保存时构建（构建中再保存则丢弃本轮并重建）；保存 build.zig 时重启；单文件模式；`zig-analyzer/waitIdle` |
| 生成文件 | `src/project/bsp.zig`、`src/project/configuration.zig`、`ProjectModel` | 模块根为生成文件（`addOptions`、`addWriteFiles`、`addTranslateC`、Run 输出等）时，从 `bsp_step_completed` 的生成文件列表得到真实路径，立即更新编译集合；构建请求额外包含所有生成模块根的产出 step，诊断 step 不依赖的模块（如只在 test step 中使用的）也能得知路径；这些额外 step 的错误不作为诊断发布 |
| 配置（最小版本） | `src/server/Config.zig` | 来自 `initializationOptions`、`workspace/didChangeConfiguration` 推送的 settings，以及向客户端拉取（`workspace/configuration`，节名 `zig-analyzer`：启动项目前拉取一次；客户端支持时动态注册配置变化通知，收到不带内容的通知后重新拉取）：`zig.path`、`build.args`（传给 `zig build` 的 `-D` 等参数）、`diagnostics.step`（不存在时提示并回落到默认规则）；构建相关配置变化时重启各项目，旧实例发布过的诊断由新实例在首次构建后清除 |
| 进度通知 | `src/server/progress.zig` | 客户端声明 `window.workDoneProgress` 时，项目加载（读取构建图、分析编译集合）、构建（`zig build <step>`，按 step 完成数给百分比与当前 step 名，结束时给错误数）与单文件编译通过 `$/progress` 报告；create 请求不阻塞构建，响应到达后补发 begin，被拒绝则不再发送 |

- 实测验证的编译器行为：编译器对从模块根沿 `@import` 可达的全部文件做 AstGen，包括只在未被调用的函数中导入的文件；根结构有致命 AstGen 错误（或解析错误）时不追踪其 import；标准库总会参与编译。编译集合按此实现，import 列表直接取自 ZIR。
- 端到端测试（真实运行 `zig build --listen=-`）：打开文件后 Sema / AstGen 错误与编译器一致，未导入的文件无诊断；未保存修改时 Sema 错误随编辑平移；保存修复后的版本重建后诊断更新（编译器继续分析到新的错误）；build.zig 本身的错误；错误前有多字节字符时 UTF-16 列号正确；单文件模式；生成的模块根文件（含 check 不依赖的）都能得知路径，且只有 check 用到的进入编译集合；进度的 begin / report / end 成对出现，客户端拒绝 token 或不支持时不发送。测试通过内存管道与独立线程中的 Server 交互（`src/server/test_harness.zig`），可等待响应并当场回复服务器请求。配置传入 `-D` 参数后被条件屏蔽的错误出现，运行中切换诊断 step 后项目重启、旧诊断清除；启动时与收到不带内容的变化通知时拉取配置。子进程后端与进程内后端在样例上结果一致。
- 实测：示例项目从启动到首次构建与编译集合完成约 1 秒（加载并 AstGen 560 个文件，含标准库）。
- 测试：`zig build test` 共 117 个；Debug 下约 30 秒，主要为集成测试启动 `zig build`。
- 与设计的差异：
  - 不使用 watch 模式：0.17 的 maker 在 watch 期间收到新的构建请求会 panic，因此改为保存时发送一次 `bsp_build_steps`；build.zig 变化时重启 maker。
  - `ProjectModel` 暂由 Workspace 持有，尚未作为查询引擎 input；M3 的名字解析需要时再接入。
  - 配置只实现了最小版本（见上表「配置」）：只来自客户端，没有项目 / 全局配置文件、多来源合并与 `config.zon` 代码生成，也没有作为查询引擎 input；`zig.path` 运行中修改需重启服务器；拉取时只取全局配置节，不按工作区（`scopeUri`）区分。其余配置项随 M4 起的功能一起加入。
  - 单文件模式只发布被编译文件自身的诊断。
  - 未保存修改时，同一文件内附注（note）的位置不随编辑平移。
- 并发：`io.async` 只表达「异步」，不保证「并发」，允许在调用方线程同步执行（`Io.Threaded` 在忙碌任务数达到「CPU 核数 - 1」时就会这样做）。因此凡是需要与调用方同时进行的任务（`waitIdle` 等会等待主循环处理后续消息的后台请求、常驻的读取任务）必须用 `concurrent`；耗时数秒的单文件编译也优先用 `concurrent`，避免阻塞主循环。有测试把 `async` 上限设为 0 覆盖这种情况。（曾误报为上游问题 ziglang/zig#37218，上游说明这是 API 语义，已关闭；本仓库 #2 同样关闭。）
- 0.17 的 maker 存在竞态：收到新的 `bsp_build_steps` 时 `select.cancelDiscard()` 可能在接收任务结束前关闭队列，随后 `select.await()` 因 `error.Closed` panic，核数越少越容易触发（单核时每次都会）。maker 意外退出时自动重启项目，连续 3 次（期间没有完成过构建）后放弃并提示。已报告上游：[ziglang/zig#37217](https://codeberg.org/ziglang/zig/issues/37217)（本仓库 #1）。
- 已知问题：同一文件可能被重复发布一次相同的诊断（构建完成与编译集合更新各触发一次），不影响结果。

### 19.5 M3 完成情况（2026-10-13）

| 模块 | 文件 | 内容 |
|---|---|---|
| 类型化访问层 | `src/syntax/ast.zig` | 声明、函数原型、参数、字段、语句与控制流、表达式的语义访问器；`memberName` 统一取成员名字（枚举成员的名字位于类型表达式位置）。ItemTree 与 documentSymbol 已迁移 |
| HIR | `src/hir/Body.zig`、`lower.zig`、`queries.zig` | 每个容器成员一个 Body（参数类型、返回类型、函数体、初始化、字段类型与默认值）；表达式、绑定、作用域与位置映射一遍算出；位置相对 owner，Body 按结构比较，内容不变时下游不重算；`ItemBody` query 以（文件, AstId）为键 |
| 模块图 | `src/names/ModuleGraph.zig` | 汇总各项目的模块（根文件、import 表）与编译集合中每个文件的模块归属，作为 input；zig 环境就绪与编译集合更新时重建 |
| 名字解析 | `src/names/resolve.zig` | 局部作用域 → 外层容器链（体内容器继续查外层函数在该位置可见的局部名字）；`a.b.c` 沿 `@import`、容器定义、`@This()` 与别名链求命名空间；import 支持相对路径、模块名、`std`、`root`；遇到未加载的文件记为缺失 |
| 功能 | `src/ide/definition.zig`、`completion.zig`、Server | goto definition（名字、成员访问、import 字符串）；补全（`a.` 之后列出成员，跨文件只列 pub；否则列出局部名字与外层容器的声明）；请求处理中遇到未加载的文件时从磁盘加载并重新计算 |

- 端到端测试：真实 `zig build` 项目中跨模块跳转、跳到 `@import` 的文件、跳进标准库（`std.mem.Allocator`）、`std.mem.` 之后的补全；单文件模式下标准库按需加载后跳转。单元测试覆盖参数 / 局部变量 / 捕获 / 标签的作用域、泛型函数返回的容器引用外层参数、`@This()`、枚举成员、缺失文件的记录。
- 语料对拍新增 HIR 检查：标准库与本仓库源码共 130 万个表达式全部降级成功，位置都在成员范围内，且每个 `name_ref` 节点在 Body 中都有对应的表达式（据此修复了 labeled switch 的 `continue :l value` 丢失操作数）；降级耗时 0.13 秒。
- 实测：单文件模式下首次跳转到 `std.mem.Allocator`（需从磁盘加载并解析 std.zig、mem.zig）约 3.5 ms，之后约 0.13 ms。
- 测试：`zig build test` 共 132 个。
- 与设计的差异：
  - 类型化访问层手写（§5.1）。
  - 命名空间没有单独的 query：成员查找直接在 ItemTree 上线性扫描，目前足够快。
  - 不依赖类型的解析范围：经由函数调用（`std.ArrayList(u8)`）、变量类型（`var x: S` 的 `x.`）、结构体字段得到的命名空间留给 M4 / M5；字段的跳转与补全同样依赖类型。
  - `@import("builtin")` 不解析（由编译器生成，不在磁盘上；2026-10-14 补上，见 §19.10）；一个文件属于多个模块时固定取第一个，`zig-analyzer/setActiveModule` 未实现；`ContainerId` 的泛型实例区分（`inst`）留到 M5。
  - 补全还不包括关键字、内置函数、原生类型与 `@import` 路径。

### 19.6 待测量的优化项

有意暂不处理、等有测量数据（M4 的类型推导或 M7 的性能评估）再决定是否处理的问题。新发现的同类问题记在这里。

| 问题 | 现状 | 何时可能成为瓶颈 | 处理方式 | 记录于 |
|---|---|---|---|---|
| 容器成员按名字查找 | `lookupDecl` 线性扫描 ItemTree 中该容器的成员，没有按容器缓存的哈希表（§7.2 的 `namespace` query） | 类型推导时大文件中大量名字查找，或成员特别多的容器 | 加一个以容器为键、值为「名字 → 成员」表的 query；只改 `lookupDecl` / `memberDef` 内部 | M3 |
| 行索引 | 每个请求现场计算 `LineIndex`，未做成 `line_index(file)` query（§12.2） | 大文件上高频请求（逐字输入时的补全、semantic tokens） | 做成 query 缓存 | M1 |
| live 诊断防抖 | 每次编辑都重新计算 live 诊断，没有防抖（§11.2）。M7 实测：Zig 编译器源码中最大的 Sema.zig（3.5 万行）上编辑到诊断 9～45 ms，其余文件 ≤ 9 ms，暂不需要 | 大文件上快速输入 | 发布前等待 ~50ms 内无新编辑 | M1 |
| 超大文件的 AstGen | 合法代码的 live 诊断需要完整 AstGen：Sema.zig 上约 45 ms，超出 30 ms 预算（有语法错误时只解析，约 9 ms）。AstGen 是官方实现，无法局部重做 | 编辑数万行的单个文件 | 只能等上游；或对超大文件放宽预算 | M7 |
| 保存后的编译器诊断 | 由编译器决定：Zig 编译器项目以 `-Dno-bin` 检查约 5 秒；`-fincremental` 约 2.6 秒，但 0.17 中漏报部分错误（文件级 `comptime` 块中的错误），macOS 上输出二进制时直接崩溃（`TODO(MachO2): load archive`），因此不自动启用，用户可经 `build.args` 自行传入。小项目约 120 ms | 大项目保存后等待诊断 | 上游增量编译成熟后默认启用 | M7 |
| live 诊断的 AstGen 不可取消 | 标准库 AstGen 计算中不检查取消，写事务需要等它结束 | 大文件上的编辑延迟 | 防抖，或把 AstGen 放到单独的计算队列 | M1 |
| InternPool 的锁 | 读写共用一把互斥锁，`key()` 读取也要加锁 | 类型推导并发请求多、InternPool 很大时的锁竞争 | 分片，或读路径改为无锁（只追加的分段数组） | M4 |
| 函数体的推导粒度 | hover、补全、inlay hint 每次对整个成员做完整推导（`Infer` 按成员缓存，编辑该成员后整体重算） | 很长的函数中逐字输入 | 按语句块增量推导，或只推导光标所需的表达式 | M4 |
| 读请求用 `async` 提交 | hover、补全等读请求与诊断发布用 `group.async`；线程池满时（核数少或常驻任务多）会在主循环中同步执行，期间收不到 `$/cancelRequest`，后续请求排队。不会死锁：这些任务不等待主循环 | 用户感到请求卡顿或取消不及时 | 读请求改为 `concurrent`（与 `waitIdle` 相同） | M4 |
| 泛型实例的内存 | 推导结果已按 LRU 回收（M7，`Infer` 上限 16384 个）；InternPool 中的实例与类型仍只增不减。实测：标准库全量推导的最大 RSS 1.24 GB；InternPool 17 万项 | 长时间运行、大量不同的实例化 | InternPool 代际回收（§9.1） | M5 |
| 实例化与 comptime 求值的推导耗时 | 同一台机器上标准库全量推导：M4 1.44 秒 → M5（实例化）1.92 秒 → M5（解释器）2.91 秒 | 大项目首次 hover / 补全 | 按需推导（只算光标所需的表达式），或延迟实例化 | M5 |
| workspace symbol 的匹配 | 每次请求遍历全部项目文件的 ItemTree 做子序列匹配，没有 trigram 索引（§10.2） | 文件很多的项目中逐字输入查询 | `file_index` 增加声明名的 trigram，先粗筛文件 | M6 |
| 引用查找的反向 import 图 | 每次查找引用都现场构建反向图；各文件的 `FileIndex` 由后台索引预先算好（M7），构建只需读取缓存。实测冷缓存下在标准库（563 个文件）上查找 `mem.Allocator` 的引用 0.36～0.43 秒（含全部文件的解析），热缓存下几十毫秒 | 更大的项目，或频繁的 document highlight | 反向 import 图做成 query | M6 |
| ProjectModel 磁盘缓存 | 未实现（§13.1）。M7 实测：Zig 编译器项目上 `zig build` 配置有 Zig 自身的缓存，项目加载约 1 秒（builtin.zig 生成按参数缓存后），冷启动预算已满足 | 配置特别慢的 build.zig | 按 §13.1 实现 | M7 |
| Body 随每次解析重新降级 | `ItemBody` 依赖 `FileAstIdMap`，任何编辑后被请求的 Body 都会重新降级（结果按结构比较，内容不变时下游不重算） | 类型推导请求大量 Body 时 | 按成员文本哈希跳过降级，或让 AstIdMap 也做 cutoff | M3 |

### 19.7 M4 完成情况（2026-10-13）

| 模块 | 文件 | 内容 |
|---|---|---|
| InternPool | `src/sema/InternPool.zig` | 类型与 comptime 值的唯一表示：原生类型、整数、指针（单项 / 多项 / 切片 / C）、数组、optional、error union、错误集、函数类型、容器（身份 = 文件 + 容器 AstId）；整数、枚举成员、enum literal、错误值、函数值；按 Zig 语法输出 |
| 类型推导 | `src/sema/infer.zig` | 双向推导：期望类型从参数、返回值、类型标注、字段初始化、`@as`、比较另一侧下推；`comptime_int`、enum literal、decl literal（`.empty`、`.init(...)`）、`null` 按期望类型转换；`if` / `switch` / `orelse` / `catch` / 带标签的块做 peer type（整数提升、`T` 与 `?T`、`null`、指针 const 合并）；捕获（optional、error union、for 元素与索引、tagged union 分支）；字段、方法（自动解引用单指针）、切片与数组的 `len`；约 60 个内置函数的结果类型；类型表达式求值为 `type` 类型的值 |
| query | `src/sema/queries.zig` | `DeclType`（函数取签名推导，const 附带 comptime 值，枚举成员为枚举值）；`Infer(成员, 签名/完整)`：签名模式不读函数体与初始化表达式；两者都有环的回退值 |
| 文件内容 | `src/syntax/queries.zig` | 新增 `SourceText`：有 `FileText` 时用它，否则从磁盘读取；名字解析与类型推导因此可以在 query 内跨文件访问任意文件，M3 的「请求层加载缺失文件后重试」随之删除 |
| 功能 | `src/ide/hover.zig`、`signature_help.zig`、`inlay_hints.zig`、`context.zig`，补全与 goto definition | hover（函数显示原型源码，其他显示 `const name: T = v`，附文档）；按类型的成员补全（实例的字段与方法、经由指针、切片与数组的 `len`，字段带类型）；跳转到字段、方法、decl literal；signature help（方法调用跳过 self）；inlay hints（无标注的局部变量类型、调用处参数名，实参与参数同名时省略） |

- 测试：`zig build test` 共 146 个。sema 测试覆盖字面量与标注、字段 / 方法 / 指针 / 切片、optional 与 error union 的各种用法、循环与捕获、带标签的块、枚举与 tagged union、decl literal、跨文件经由标准库；IDE 测试覆盖 hover、补全、跳转、signature help、inlay hints；端到端测试在真实标准库上验证 `std.mem.Allocator` 的 hover、成员补全与 inlay hint。
- 标准库上的推导（`zig build sema-corpus`，563 个文件、9 万个成员、100 万个表达式，ReleaseSafe 0.8 秒，无崩溃）：声明类型已知 95.7%，局部变量 74.2%，表达式 78.7%。未知部分主要来自泛型与依赖 comptime 参数的返回类型（M5）。
- 准确率抽查：从推出类型的局部变量中按固定间隔抽取 15 个，与源码逐个核对，全部正确；其中一个是带对齐的切片，显示时省略了对齐。
- 与设计的差异与未实现：
  - 推导的错误集（`!T`）暂以 `anyerror` 表示；由函数体推导错误集未实现。
  - 指针类型不记录对齐与 `volatile` / `allowzero`；没有向量、元组与匿名结构体类型（`.{ a, b }` 为 unknown）；浮点值与算术的 comptime 折叠未实现。
  - ~~期望类型驱动的 `.` 补全（`const c: Color = .|`）未实现~~：已完成（2026-10-14）。`.` 后没有名字时解析为缺少名字的枚举字面量，推导结果记录枚举字面量的期望类型（`Result.literal_expected`），补全列出枚举成员、union 字段与可作为 decl literal 的声明（类型为 `T` 的常量、返回 `T` / `!T` 的函数）。
  - 容器类型只显示声明它的成员名（`Allocator`），不显示完整路径。
  - `SourceText` 从磁盘读到的内容不会随磁盘变化而失效（编辑器打开的文件与项目编译集合中的文件不受影响，它们由 `FileText` 管理）。
  - 泛型实例与 comptime 调用求值（`std.ArrayList(u8)`、`fn max(comptime T: type, ...) T` 的返回类型）属于 M5。

### 19.8 M5 完成情况（2026-10-14）

第一版（2026-10-13）在 M4 的推导器上增加「实例」，没有解释器。复查发现：交付中的解释器、`@typeInfo`/`@Type`、调用点种子缺失，`std.meta` 系列与 `MultiArrayList.items(.field)` 的验收不通过，并有多类给出错误结果（而非未知）的问题。2026-10-14 补全：

| 部分 | 文件 | 内容 |
|---|---|---|
| 实例 | `src/sema/InternPool.zig` | `instance { 函数, 各参数的值, 外层实例 }`；非 comptime 参数的占位 `runtime`（与未知的 comptime 实参区分）；容器类型与函数值带上所属实例；`opaque_param` 为抽象参数 |
| 值与类型 | `src/sema/InternPool.zig` | 聚合（数组、元组、结构体、切片）、字符串、union 值、指针值、浮点值；元组、向量、匿名结构体、内置函数构造的类型（身份 = 构造位置 + 内容）、`union(enum)` 的标签枚举、推导的错误集 |
| 值的语义 | `src/sema/value.zig`、`eval.zig` | 按位宽的整数运算（回绕、饱和、溢出时无值）、浮点运算；值与类型的相等（`?bool`：取决于抽象参数或未知实参时为未知；同一位置、不同实例的容器按捕获的值判断，与编译器一致）；值的类型转换；comptime-only 类型；大小与对齐 |
| 解释器 | `src/sema/eval.zig` | §9.4：可修改的值、循环、指针、`@typeInfo` 构造值、类型构造的内置函数；`CallEval` query；燃料 |
| 推导 | `src/sema/infer.zig`、`queries.zig` | 实参按实例中的参数类型转换（参数类型依赖其他参数时分两步）；隐式 comptime 参数（`T: type`）；返回 comptime-only 类型的调用全部实参参与实例；comptime 上下文中求不出的值交给解释器；带标签的块、`[_]T{}`、元组与匿名结构体字面量、`@sizeOf`/`@hasDecl` 等的值；推导的错误集（`ErrorSetOf`）；函数声明不带自身的实例（递归的类型函数可识别为环） |
| 引擎 | `src/db/engine.zig` | 原生栈深度上限、不完整的结果不写入 memo、迭代加深、读事务的燃料（§6.4） |
| HIR / 语法 | `src/hir/`、`src/syntax/` | `.container` 记录参数表达式（`enum(u8)`、`union(E)`）；`@"name"` 形式的标识符以去掉引号的名字参与语义 |
| IDE | `src/ide/` | 构造的类型、元组、匿名结构体的成员补全；hover 的调用点种子（`seed.zig`）；值的显示带字段名、过长时截断 |

- 验收（真实标准库，与编译器逐项核对）：`std.meta` 的 `Child`/`Elem`/`Sentinel`/`Tag`/`activeTag`/`FieldEnum`/`DeclEnum`/`ArgsTuple`/`BackingInt`/`Slice`/`tags`/`fieldInfo`，`MultiArrayList(T).items(.field)` 与 `Slice.items`，`std.mem.SliceTo`、`std.math.maxInt` 均推导正确；`FieldEnum(S)` 等构造的类型以构造它的函数实例命名（编译器显示为 `meta.FieldEnum(main.S)`）。
- 修复的错误结果：依赖其他参数类型的 comptime 实参未转换（switch 选错分支、同一类型有两个身份）；实参未知的不同实例被合并为同一类型；常量折叠不按位宽；抽象参数下的类型比较给出确定结果；`!@TypeOf(x)` 丢失错误联合；嵌套深度上限使结果依赖求值顺序并泄漏抽象参数；长依赖链栈溢出；不写 `comptime` 的类型参数（`fn f(T: type)`）未识别为 comptime。
- 标准库全量统计（`zig build sema-corpus`，同一台机器）：

| 指标 | M4 | M5 第一版 | M5 |
|---|---|---|---|
| 声明类型已知 | 95.7% | 96.3% | 97.2% |
| 局部变量类型已知 | 74.2% | 86.2% | 89.3% |
| 表达式类型已知 | 78.7% | 86.6% | 90.7% |
| 全量推导耗时（ReleaseSafe） | 1.44 秒 | 1.92 秒 | 2.91 秒 |

- 测试：`zig build test` 共 169 个（Debug 与 ReleaseSafe 均通过），新增按位宽折叠、实参转换与实例身份（含按捕获值比较容器）、比较结果未知、推导的错误集、带标签的块、解释器（循环、修改、指针捕获、递归的类型函数）、深链、`std.meta` 系列、反射与类型构造、浮点、构造类型的补全、调用点种子等用例。
- 未实现（与设计的差异）：调用点种子只在同一文件中查找（跨文件查找已在 M6 完成，见 §19.12）；其余见 §19.9。

### 19.9 M5 遗留事项

尚未排入里程碑的已知限制，按优先级排列。除与目标相关的大小外，它们只会使结果为未知或不够精确，不会给出错误结果。

| 优先级 | 事项 | 现状 | 做法 |
|---|---|---|---|
| ~~高~~ | ~~`@import("builtin")` 的解析（M3 遗留）~~ | 已完成，见 §19.10 | — |
| ~~高~~ | ~~与目标相关的大小给出错误结果~~ | 已消除，见 §19.11：位宽取项目的目标；各模块宽度不一致时与大小相关的值为未知 | — |
| 低 | 混合指针宽度的项目中与大小相关的值 | 同一项目同时有不同指针宽度的目标（如宿主工具与 wasm32 产物）时，`@sizeOf(usize)`、`maxInt(usize)` 等为未知（不会出错） | 「目标」进入 `Infer` / `DeclType` / `CallEval` 的键，同一文件按所在模块各推导一份 |
| ~~中~~ | ~~递归函数的推导错误集~~ | 已完成，见 §19.14：取最小不动点 | — |
| ~~低~~ | ~~浮点的数学内置函数（`@sqrt`、`@sin` 等）、`@offsetOf`、auto 布局容器的大小~~ | 已完成，见 §19.14：照搬编译器的布局算法；不带标签的 auto union、显式对齐的字段等仍为未知 | — |

### 19.10 `@import("builtin")` 的解析（2026-10-14）

| 部分 | 文件 | 内容 |
|---|---|---|
| 模块参数 | `src/project/configuration.zig`、`ProjectModel` | 从构建图提取每个模块影响 builtin 的参数，写法与构建系统传给编译器的一致：`-target` / `-mcpu`、`-O`、`-f[no-]single-threaded` / `error-tracing` / `PIC` / `valgrind` / `fuzz` 等、unwind tables、code model、`-lc` / `-lc++`；子命令取以该模块为根的 compile step（`build-exe` / `build-lib` / `build-obj` / `test`，决定 `output_mode` 与 `is_test`） |
| 生成 | `src/project/builtin.zig` | 运行 `zig <子命令> --show-builtin <参数>`，按内容哈希写入 `<全局缓存>/zig-analyzer/builtin/<hash>/builtin.zig`（内容不变路径不变；落盘使 goto definition 可以打开）；Workspace 加载构建图后为每种参数生成一次 |
| 解析 | `ModuleGraph`、`resolve.zig` | 每个模块记录自己的 builtin；标准库文件取所在 compile step 根模块的 builtin（与编译器一致）；不属于任何模块的文件（单文件模式）取默认 builtin（本机目标、Debug，与单文件编译一致） |

- 端到端测试：配置 `-Dtarget=x86_64-linux -Doptimize=ReleaseFast` 的项目中 `builtin.os.tag` 为 `.linux`、`builtin.mode` 为 `.fast`，`@import("builtin")` 跳转到生成的文件；单文件模式下为本机目标与 Debug。
- 标准库全量统计（`sema-corpus` 使用默认 builtin）：声明类型已知 97.2% → 99.4%，局部变量 89.3% → 90.9%，表达式 90.7% → 92.2%。
- 测试：`zig build test` 共 172 个。

### 19.11 与目标相关的大小（2026-10-14）

- 指针位宽（`usize`、`isize`、指针与切片的大小）不再固定为 zig-analyzer 自身的构建目标：Server 更新模块图时从各模块的 builtin.zig 解析 `cpu.arch` 与 `abi`，按 `std.Target.ptrBitWidth_arch_abi` 计算；各模块一致时取该宽度，不一致时为未知；没有项目模块时取默认 builtin（本机）。
- 位宽同时写入 `PointerBits` input（后改为 `TargetAbi`，见 §19.15）与 `InternPool.pointer_bits`（同一写事务），`value.zig` 的值运算读后者；`Infer`、`DeclType`、`CallEval`、`ErrorSetOf` 在计算开始时读前者以记录依赖，目标变化时依赖它的结果失效（只依赖 `@sizeOf(usize)`、不 import 任何文件的代码也会重算，由测试覆盖）。
- 端到端测试：wasm32 项目中 `@sizeOf(usize)` 为 4、`std.math.maxInt(usize)` 为 4294967295；同时有宿主与 wasm32 目标的项目中两者为未知；单文件模式为本机宽度；配置变更去掉 `-Dtarget` 后结果随之更新。
- 同时修复：`zig env` 原样输出相对路径的 `ZIG_GLOBAL_CACHE_DIR`（CI 即如此设置），`ZigEnv` 现在把 `lib_dir`、`std_dir`、`global_cache_dir` 转为绝对路径；此前生成的 builtin.zig 路径为相对路径，导致 CI 上三个平台的测试失败。
- 测试：`zig build test` 共 175 个。

### 19.12 M6 完成情况（2026-10-14）

| 部分 | 文件 | 内容 |
|---|---|---|
| 文件索引 | `src/ide_db/FileIndex.zig` | 每个文件出现的标识符名字（去掉 `@"..."`，排序后二分查找）与 `@import` 字符串；derived query，名字与 import 不变时下游不重算 |
| 引用查找 | `src/ide_db/search.zig` | 局部名字只搜所在成员及其体内容器的成员；声明先取能经由 `@import` 链到达定义所在文件的文件，再按文件索引粗筛，只解析提到该名字的成员。名字引用经名字解析确认；字段访问先求命名空间，求不出时读该成员的推导结果；枚举字面量（含 switch 分支）与初始化中的字段名读推导结果（`Result.members`、新增的 `Result.field_refs`） |
| 服务器 | `src/server/Server.zig` | `textDocument/references`、`documentHighlight`、`prepareRename` / `rename`、`workspace/symbol`、`codeAction`。范围为模块图中的项目文件（不含标准库）与打开的文档。重命名只允许工作区根目录内（不含 `.zig-cache`、`zig-pkg`）的定义；新名字是关键字或含特殊字符时用 `@"..."` 包裹 |
| workspace symbol | `src/ide/workspace_symbol.zig` | 忽略大小写的子序列匹配，完全相同、前缀、子序列依次排序，最多 256 个 |
| code actions | `src/ide/code_actions.zig` | 未使用的局部常量 / 变量 / 参数 / 捕获插入 `_ = x;`；删除多余的丢弃；switch 补上缺少的枚举与联合分支；结构体初始化补上没有默认值的字段（`= undefined`） |
| 调用点种子 | `src/ide/seed.zig` | 同一文件找不到时，在能引用到该泛型函数、且文件索引中有其名字的项目文件中查找 |

- 同时修复：联合中只写名字的字段（`union(enum) { a: u8, b }` 的 `b`）此前在 ItemTree 中没有名字，跳转、补全、switch 分支都看不到它；现在与枚举成员一样取类型表达式位置的名字。
- 验收：`sema-corpus` 在标准库上（563 个文件、冷缓存）查找 `mem.Allocator`、`mem.eql`、`std.ArrayList` 的引用分别为 0.36～0.43 秒、约 50 毫秒、不到 10 毫秒，满足 < 1 秒。
- 已知限制：经由别名的使用不计入（`const Allocator = std.mem.Allocator;` 之后的 `Allocator` 是别名的引用，与 rust-analyzer 一致）；标准库内部的引用不搜索；推导不出类型的字段访问找不到。
- 测试：`zig build test` 共 185 个。

### 19.13 M7 完成情况（2026-10-14）

基准工具 `tools/lsp_bench.zig`（`zig build bench -Doptimize=ReleaseSafe -- <项目> <文件>...`）以子进程启动服务器，按编辑器的方式交互，测量 §1 的各项预算。以下数据取自 Zig 0.17.0 编译器源码（182 个文件、54 万行，另加标准库），Apple Silicon，ReleaseSafe。

| 预算 | 目标 | 实测 | |
|---|---|---|---|
| hover / goto | p95 < 50 ms | 首轮最慢 34 ms；热状态 p95 ≤ 1.3 ms | ✅ |
| completion | p95 < 100 ms | 首轮最慢 13 ms；热状态 p95 ≤ 0.9 ms | ✅ |
| 编辑 → 语法 / AstGen 诊断 | < 30 ms | Sema.zig（3.5 万行）9～45 ms，其余文件 ≤ 9 ms | ⚠️ 超大文件受 AstGen 限制 |
| 保存 → 编译器诊断 | < 1 s | 小项目约 120 ms；Zig 编译器 5.2 s（编译器耗时） | ⚠️ 受编译器限制，见 §19.6 |
| 常驻内存 | < 500 MB | 打开三个大文件、各做 600 次请求后 361 MB | ✅ |
| initialize | < 100 ms | 1～9 ms（新编译的二进制首次启动受系统校验影响约 0.4 s） | ✅ |
| 打开文件 → 语法功能 | < 200 ms | Sema.zig 53 ms | ✅ |
| 打开文件 → hover 可用 | < 3 s | 项目加载 1.5 s；加载前的 hover 也可用（名字解析不完整） | ✅ |
| 工作区索引 | < 30 s | 1.9 s 完成 | ✅ |

冷启动预算已满足，不需要把 §6.7 的分析结果持久化提前。

| 改动 | 文件 | 测量依据与效果 |
|---|---|---|
| 绿树压缩 | `src/syntax/green.zig` | 解析结果占源码的 20 倍：每个 token（含空白、注释）一个 32 字节的标签联合。改为 16 字节的紧凑结构（指针 + 长度 + 种类 + 是否节点），降到 12.7 倍（Zig 编译器源码 504 MB → 316 MB） |
| 查询结果淘汰（§6.6） | `src/db/engine.zig` | derived query 可声明 `lru` 容量；超出后在写事务开始时或读请求结束后（`trySweep`：只在没有其他读事务时进行，读写锁写者优先，排队的清扫会挡住之后的读请求）淘汰最久未使用的值，保留依赖与 changed_at。被淘汰的值在验证通过时重算并沿用原 changed_at，下游不重算；验证依赖时不恢复值。`ParseFile`、`FileAstIdMap` 上限 64（AstIdMap 持有 Parse 的引用，二者可各自淘汰），`ItemBody`、`Infer` 上限 16384。常驻内存 805 MB → 361 MB |
| 后台索引 | `src/server/Server.zig` | 一次 hover 的跨文件调用点种子为构建反向 import 图在请求中解析了 174 个文件（352 ms、+400 MB）。模块图更新后在后台为全部项目文件计算 `FileIndex` 与 ItemTree（同时只运行一个任务，模块图又变化时再做一遍；超过 200 ms 才显示进度），该 hover 降到 34 ms |
| 调用点种子 | `src/ide/seed.zig` | 只推导提到该函数名的成员 |
| builtin.zig 生成 | `src/project/builtin.zig`、`Workspace.zig` | 项目加载 16.6 s 中几乎全部用于为每组模块参数串行运行 `zig --show-builtin`。按「zig 版本 + 参数」记录生成结果，并行生成：首次 3.2 s，之后约 1 s |

- 淘汰带来的副作用及处理：
  - 被淘汰的解析结果使重复的引用查找回到冷缓存的速度：新增 `ItemSummaries` query（各成员与容器的起始位置、成员内标识符的 256 位布隆过滤器，不淘汰），引用查找与调用点种子用它定位并粗筛成员，只为可能提到该名字的成员生成 Body；体内容器的定位（名字层、求值器、推导器）也改用它。标准库上淘汰解析结果后再次查找 `mem.Allocator` 的引用：重新解析 115 个文件、100 ms → 5 个文件、6 ms
  - 恢复被淘汰的值时可能因本次请求的 comptime 燃料不足而得到不完整的结果：恢复使用独立的燃料
- 调用点种子只推导提到函数名的成员后会漏掉经由别名的调用：新增 `Resolver.aliasTarget`，先收集指向该函数的容器级别名（含别名的别名，跨文件），按函数名与全部别名筛选
- 验证：`sema-corpus` 每个文件之后按需淘汰（标准库上 114 次），统计结果与不淘汰时完全相同，Debug 与 ReleaseSafe 下均无崩溃与泄漏；引擎单测覆盖淘汰后恢复不使下游重算、依赖变化照常重算。
- 同时修复：一条日志中的中文标点；builtin.zig 写入缓存失败或被取消时泄漏路径字符串。
- 测试运行器：构建时在 Zig 自带的运行器上开启测试分配器的调用栈记录（`tools/patch_test_runner.zig`），测试模块保留帧指针，ReleaseSafe 下的泄漏报告也带调用栈（CI 上曾偶发一次无法定位的泄漏）。
- 测试：`zig build test` 共 189 个。

### 19.14 递归函数的错误集、浮点数学函数与布局（2026-10-14）

补全 §19.9 中的两项。对照编译器实现时，另外修正了 `@min` / `@max` 的结果类型，并补上了不同整数类型、不同浮点类型之间的 peer 类型。

| 部分 | 文件 | 内容 |
|---|---|---|
| 不动点 | `src/db/engine.zig` | query 可声明 `fixpoint`：`cycleFallback` 是值的最小元，环中对自身的读取只把读到的值并入结果。这时环的入口算一遍即得最小不动点，入口的结果写入 memo，环内其他 query 的结果仍不写入。栈深度超过上限不是环，回退值改由 `depthFallback` 给出 |
| 推导的错误集 | `src/sema/queries.zig` | `ErrorSetOf` 声明 `fixpoint`：环中取空错误集（InternPool 新增预置的 `empty_error_set`），栈深度超过上限取 anyerror。自身递归的函数与编译器一致，如 `return rec(n - 1)` 的错误集只含函数体中 `return` 的错误；相互递归（编译器报错）取各函数错误的并集 |
| 布局 | `src/sema/eval.zig`、`value.zig` | 照搬编译器的算法（`Sema/type_resolution.zig`）。auto 结构体按对齐降序重排字段，与编译器同样用 `std.mem.sortUnstable` 和相同的比较函数，对齐相同的字段顺序也一致；comptime 字段不占空间。extern 按声明顺序。packed 的 backing 整数为各字段位宽之和，字段须为整数、浮点、bool、void、指定了标签类型的枚举或 packed 容器。带标签的 union 为最大字段加标签，只有一个字段时没有标签；extern union 不带标签；packed union 的各字段位宽相同。枚举取标签整数的布局。错误联合与非指针的 optional 由载荷求出。`@offsetOf` / `@bitOffsetOf` 由同一布局求出 |
| `@bitSizeOf` | 同上 | 只对有位表示的类型给出值。切片、非指针的 optional、错误联合与非 packed 的容器没有位表示（编译器报错），此前给出了值。数组的位宽为（长度 + 哨兵）× 元素位宽，且要求元素有位表示 |
| 浮点 | `src/sema/value.zig`、`eval.zig`、`InternPool.zig` | `@sqrt`、`@sin`、`@cos`、`@tan`、`@exp`、`@exp2`、`@log`、`@log2`、`@log10`、`@floor`、`@ceil`、`@trunc`、`@round`、`@abs`、`@mulAdd`，以及浮点参数的 `@min`/`@max`/`@mod`/`@rem`/`@divTrunc`/`@divFloor`/`@divCeil`/`@divExact`：按操作数的浮点类型计算（comptime_float 按 f128），与编译器一致。浮点值按其类型的精度显示（f32 的 √2 为 1.4142135） |
| `@min` / `@max` | `src/sema/value.zig`、`eval.zig`、`infer.zig` | 结果类型与编译器一致（此前取 peer 类型）：有浮点参数时为位宽最大的浮点类型；整数为容纳结果范围的最小整数类型，各参数的范围在值已知时取该值、否则取类型的范围。如 `@min(x: u8, y: u16)` 为 u8，`@min(x, 10)` 为 u4，`@min(@as(u8, 3), @as(u16, 5))` 为 u2 |
| peer 类型 | `src/sema/infer.zig` | 不同的整数类型之间、不同的浮点类型之间的 peer 类型（此前为未知，如 `usize + u32`）：整数同符号取较宽者、位宽相同取前者（`usize + u64` 为 usize），无符号且较窄时放入有符号；浮点取位宽较大者。与编译器一致 |
| 推导器 | `src/sema/infer.zig` | 参数都已知时，数学函数与布局由解释器计算（`eval.builtinValue`、`eval.typeLayout`）；有符号整数的 `@abs` 为同位宽的无符号整数 |
| 构造类型 | `src/sema/eval.zig` | `@Struct` / `@Union` / `@Enum` 中按字段给出的参数带上结果类型 `*const [n]T`，与编译器一致，`&@splat(.{})` 等写法可以求值（如 `std.enums.EnumFieldStruct`）。字段属性带 comptime 或显式对齐时记录在类型中，这时布局为未知 |

- 当时仍为未知的：不带标签的 auto union、字段的显式对齐、元组与匿名结构体字面量、向量、负除数的浮点 `@mod`、`c_long` 等 C 类型。前五项其实都能求出，已在 §19.15 补全（原先「优化模式不是推导的输入」的判断有误：模块的 builtin.zig 中有优化模式）。
- 同时修复：解释器中 i128 的最小值参与整数除法时溢出会触发安全检查（进程崩溃），现在放弃求值。
- 验证：布局（含字段重排、comptime 字段、零大小字段、嵌套的容器、构造的类型）与浮点结果逐项与 zig 0.17.0 编译运行的结果核对（x86_64-linux）。
- 标准库全量统计：声明类型已知 36997 → 37008（99.3%），局部变量 36926 → 37236（90.9% → 91.7%），表达式 940132 → 942393（92.1% → 92.4%），增加的主要来自 peer 类型；逐个成员对比，没有成员的未知表达式变多。耗时不变（ReleaseSafe 约 3.9 秒）。
- 测试：`zig build test` 共 197 个（Debug 与 ReleaseSafe 均通过）。

### 19.15 §19.14 遗留项的补全（2026-10-15）

| 部分 | 文件 | 内容 |
|---|---|---|
| 浮点除法 | `src/sema/value.zig` | 编译器在 comptime 调用自身的 `@mod`、`@divTrunc` 等，发行版的编译器经 LLVM 编译，展开为固定形式（`@mod` 为 `lhs < 0 ? fmod(fmod(lhs, rhs) + rhs, rhs) : fmod(lhs, rhs)`，只按被除数的符号调整）。按同样的展开式计算，负除数时与编译器一致（f64 的 7 mod -3 得 1），结果也不随 zig-analyzer 自身的编译后端变化 |
| 显式对齐 | `src/hir/`、`infer.zig`、`eval.zig` | HIR 记录字段与变量的 `align(...)` 表达式，签名模式的推导在 comptime 求值；布局使用它（可大于或小于类型的对齐，参与重排；泛型实例中按实参求值）。`@Struct` / `@Union` 字段属性中的对齐与 comptime 字段记录在构造的类型中；`@typeInfo` 报告字段的 `align` 与 `comptime` |
| 不带标签的 union | `src/sema/eval.zig` | 与编译器的 `wantSafeTypes` 一致：所在模块的 builtin 中 `optimize` 为 Debug 或 ReleaseSafe 时有隐藏标签（取容纳字段序号的最小无符号整数），ReleaseFast / ReleaseSmall 时没有；`@Union` 构造的同样处理 |
| 向量 | `src/project/`、`src/server/Server.zig`、`value.zig` | 布局取决于编译后端与 CPU 特性：自研 x86_64 后端对齐至少为 16（AVX 下超过 16 字节为 32，AVX-512 下超过 32 字节为 64），LLVM 等后端为不小于字节数的 2 的幂（aarch64 不超过 16），C 与 wasm 后端按元素对齐。从各模块 builtin.zig 的 `zig_backend` 与 `cpu.features` 取得，各模块一致时使用；生成 builtin 时补上 compile step 的 `use_llvm`（`-fllvm` / `-fno-llvm`），此前在 build.zig 中指定时 `zig_backend` 与实际不符。`PointerBits` input 改为 `TargetAbi`，同时携带指针位宽与向量的规则 |
| 元组与匿名结构体字面量 | `src/sema/InternPool.zig`、`infer.zig`、`eval.zig`、`value.zig` | 类型记录各字段的 comptime 值：与编译器一致，字面量中 comptime 已知的字段（含 `{}`、字符串、只有一个可能值的类型）是 comptime 字段，`struct { comptime u8 = 1, u32 }` 与 `struct { u8, u32 }` 是不同的类型，显示也与编译器相同（空元组为 `@TypeOf(.{})`）。推导器按编译器的规则判断值未推出的字段：局部 var、参数、普通函数的调用、非 inline 循环的捕获、容器级 var 是运行时的；判断不了的（如 inline 函数的结果）标为未定，这时布局为未知。解释器构造的元组字段都是 comptime 字段。元组按声明顺序布局（不重排；对齐计入零大小的字段，大小不计入），匿名结构体与 auto 结构体相同；comptime 字段不占空间，也不使类型成为 comptime-only。下标已知时取元组字段的类型，comptime 字段的值属于类型；`@typeInfo` 报告 comptime 字段与其默认值 |

- 验证：逐项与 zig 0.17.0 编译运行的结果核对。向量另在五种配置下核对：x86_64 自研后端（AVX、AVX-512、无 AVX）、`-fllvm`、aarch64；e2e 测试中 wasm32 项目的 `@sizeOf(@Vector(2, u8))` 为 2，宿主与 wasm32 混合时为未知。
- 仍为未知（不会给出错误结果）：
  - 声明所在的函数体中调用了 `@setRuntimeSafety` 时，不带标签的 union 是否有隐藏标签。
  - 推导不出的对齐表达式。
  - 元组字面量中是否 comptime 判断不了的字段（如 inline 函数的结果、多行字符串）：布局为未知，显示按运行时字段。
  - 向量：各模块的后端或 CPU 特性不一致时；f80、f128 元素（是否软浮点取决于 long double）；x86 的软浮点；未覆盖的架构（ARM、s390x 的对齐上限为各自的栈对齐，MIPS 与 PowerPC 的 f16 为软浮点）。
  - `c_long` 等 C 类型：目标可从 builtin.zig 得到，可用 `std.Target.cTypeBitSize` 计算，尚未实现。
- 标准库全量统计：声明类型已知 37012（99.3%），局部变量 37246（91.7%），表达式 942857（92.4%）；与 82f1304 交替测量耗时，两者都在 4.1～4.7 秒之间，没有可测出的差别。
- 测试：`zig build test` 共 201 个（Debug 与 ReleaseSafe 均通过）。

### 19.16 统计口径的修正（2026-10-15）

- 问题：enum 成员（以及 union 中只写名字的字段，如 `union(enum) { a: u8, b }` 的 `b`）的名字在 HIR 中被降级为字段的类型表达式，推导器把它当作名字引用解析。解析不到时计为未知的表达式（标准库中约 2.9 万个，主要来自各架构的系统调用枚举），解析到同名声明时计为已知（约 5000 个）。后者同时使查找引用、重命名、跳转与 hover 把枚举成员当作同名声明的引用，如 `std.os.linux.read` 的引用中包含各架构 `SYS` 枚举的成员 `read`。
- 修复：降级时由 ItemTree 得到所在容器的种类，enum 与 union 中没有 `:` 的字段不再降级出类型表达式（元组式结构体的字段同样没有 `:`，那里仍是类型）；union 中只写名字的字段类型为 void，此前为未知。`zig build corpus` 中 HIR 名字引用个数的核对同步排除这个名字。
- `_ = x;` 中的 `_` 是丢弃，不再计入 `sema-corpus` 的表达式统计（3015 个）。
- 新口径下的标准库统计：声明类型已知 37012/37265（99.3%），局部变量 37251/40626（91.7%），表达式 937790/983121（95.4%）。§19.8～§19.15 中的表达式统计含上述约 3.7 万个不是表达式的项，同一时刻按旧口径为 92.4%。
- 测试：`zig build test` 共 203 个。

### 19.17 结果类型的传递与常见缺口（2026-10-15）

| 部分 | 文件 | 内容 |
|---|---|---|
| 结果类型 | `src/sema/infer.zig` | 与编译器一致地把结果类型传给子表达式：decl literal 去掉 error union、optional 与单项指针后查找（`const t: *T = .current()`、`const x: ?S = .empty`）；`try .init()` 把结果类型交给 decl literal（编译器中 `try` 只对这种形式传递结果类型，`catch` / `orelse` 的左侧不传）；`.{ ... }` 的类型为结果类型去掉 error union 与 optional，字段按向量、元组、构造的类型与匿名结构体的字段类型推导；`&.{ a, b }` 转换为切片或多项指针时按 `[2]T` 推导；循环的 `break` 值与 `else` 分支取循环的结果类型；labeled switch 的 `continue :l v` 按操作数的类型推导；移位的右侧为 `Log2Int(T)`（`<<|` 没有结果类型），多项指针 `+=` / `-=` 的右侧为 usize；带显式标签类型的枚举成员的值按标签类型推导 |
| 内置函数 | `src/sema/infer.zig`、`eval.zig` | 转换类的目标类型按编译器的 `resolveDestType` 去掉 error union / optional；`@constCast` / `@volatileCast` 为参数类型去掉 const / volatile；嵌套的指针转换在编译器中合并为一次，内层取外层的结果类型（`@alignCast(@fieldParentPtr(...))` 由此有类型）；`@intFromEnum` / `@backingInt` 的类型与值（含带标签的 union 与 packed 容器），`@fromBackingInt` 的参数取目标的 backing 整数；原子操作、`@mulAdd`、`@splat`、`@memset`、`@unionInit`、`@reduce`、`@call`、`@branchHint` 等的参数按各自的结果类型推导；补上 `@clz` / `@ctz` / `@popCount`、溢出算术（`struct { T, u1 }`）、`@select` / `@shuffle`、`@returnAddress` 等的结果类型；`@field` 的字段名可以是 comptime 已知的字符串；除法与取余为两侧的 peer |
| 切片与 `++` | `src/sema/infer.zig`、`eval.zig` | 切片与编译器的 `analyzeSlice` 一致：长度 comptime 已知时为指向数组的指针（`arr[0..4]` 为 `*[4]u8`），切到末尾（含结束位置等于长度）时保留哨兵，多项指针不给结束位置时仍为多项指针，单项指针按长度 1 切片。`++` 与 `zirArrayCat` 一致：元组相接为元组（comptime 字段保持），数组与指向数组的指针相接为数组，任一侧是指针时为 `*const [N]T`；只有一侧有哨兵时保留它（解释器此前要求两侧都有） |
| peer 类型 | `src/sema/infer.zig` | 长度不同的数组指针统一为切片（`if (c) "abc" else "hello"` 为 `[:0]const u8`），数组指针与切片、多项指针统一为后者，哨兵只在两侧相同时保留（此前保留前者的哨兵）；optional 与另一侧按载荷的 peer 包为 optional；向量的比较为 `@Vector(n, bool)` |
| 其他 | `src/hir/`、`src/sema/queries.zig`、`infer.zig` | HIR 记录 `align` / `addrspace` / `linksection` / `callconv` 子句中的表达式（此前不在表达式树中，从未推导），分别按 `u29`、`AddressSpace`、`[]const u8`、`CallingConvention` 推导，`callconv(.naked)` 等可以跳转；元组声明 `struct { A, B }` 与编译器一致是结构化的元组类型（此前为具名容器，下标、解构与初始化取不到字段类型）；解构 `const a, const b = x;` 按元组、数组、向量的元素推导；extern 函数的无名参数以空名绑定，类型得到推导；经由函数指针的调用；多个分支项的 union 捕获为各字段类型的 peer，第二个捕获为标签类型；`@import` 的参数 |

- 验证：各项与 zig 0.17.0 编译运行的结果核对（x86_64-linux）。
- 标准库全量统计：声明类型已知 37012 → 37045（99.4%），局部变量 37251 → 38425（91.7% → 94.6%），表达式 937790 → 955423（95.4% → 97.2%），未知的表达式 45331 → 27698。与 73c8565 对比耗时不变（ReleaseSafe 约 4.2 秒）。
- 剩余的未知中约 1.2 万个位于泛型函数中；其余主要是其他目标的代码（如 `posix.system` 中当前目标没有的声明）、依赖 `builtin.is_test` 的 `std.testing.allocator`，以及由它们传播出的部分。另有 `"..." ++ @typeName(T)`（编译器中 `@typeName` 为 `*const [N:0]u8`，长度取决于类型名，这里仍按切片处理）与 `@embedFile`。
- 测试：`zig build test` 共 217 个（Debug 与 ReleaseSafe 均通过）。

## 20. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| Zig 语法/语义随版本变化 | 自研解析器与 sema 需跟进 | 语法定义集中在 `grammar.zon` + 生成；corpus 对拍每日跑 nightly |
| 构建系统协议 / `Configuration` 格式随版本变化 | 无法获取项目模型 | 握手校验 `build_system_version`，不匹配时提示并降级为单文件模式；发布版本与 Zig 版本一一对应 |
| comptime 解释器复杂度 | 工期、性能 | 燃料上限 + `unknown` 兜底；先覆盖 std 中高频模式，以测试集驱动 |
| 自研 CST 与 `std.zig.Ast` 行为不一致 | 结构差异导致错误定位偏差 | corpus 对拍；格式化与 AstGen 始终用标准库 |
| InternPool 只增不减 | 长时间运行内存增长 | 监控 + 设上限；v2 引入代际回收或重启引擎状态 |
| 查询引擎开销 | 小请求反而变慢 | 小 query 合并；热点 query 跳过依赖记录（标记为「易变」直接重算） |
| 内置标准库与用户 zig 版本不同 | 进程内 AstGen 结果可能与编译器不同 | 版本不等时强制走 `zig ast-check` 慢路径；版本判断精确到 nightly 提交哈希 |
| `-fincremental` 不成熟 | 增量编译崩溃或结果错误 | 检测编译器异常退出后自动回退非增量模式；配置可关闭 |
| 大项目全量编译慢 | 保存后诊断延迟高 | 默认优先 `check` step（通常 `-fno-emit-bin`）；文档引导用户定义 `check` step |
| 构建参数与用户命令行不同 | 「一致」的基准不同 | 配置显式声明构建参数，状态栏展示当前使用的 step 与参数 |
| Zig `std.Io` 等 API 变动 | 并发层重写 | 并发原语封装在 `server/scheduler.zig` 与 `db/` 内部 |

---

## 21. 待决策事项

1. **实现语言**：Zig（推荐：自举、可直接用 `std.zig` 的格式化与 AstGen、便于社区贡献）vs Rust（可直接用 salsa/rowan，生态成熟，但与 Zig 工具链脱节）。
2. **解析器**：自研容错 CST（推荐，见 §5.1）vs 直接用 `std.zig.Ast`（工期短，但补全与局部重解析受限）。
3. **Zig 版本策略**：只支持 nightly vs 最新 release + nightly（推荐后者，决定构建协议适配与语法维护份数）。
4. **调用点种子推导**默认开启与否（影响泛型函数体内的 hover 体验与可解释性）。

