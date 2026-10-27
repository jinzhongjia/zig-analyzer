# zig-analyzer

[English](README.md) | 简体中文

基于增量查询引擎的 Zig 语言服务器（LSP）。

- **诊断与编译器一致**：错误只来自 Zig 官方实现（编辑时进程内的 AstGen，保存时的 `zig build`），不靠猜测。
- **真正的 comptime 求值**：泛型与类型构造按实际求值，不做模式匹配；泛型函数体以调用点的实例分析。
- **构建系统集成**：项目模型来自官方构建系统协议（`zig build --listen=-`），不维护自定义的 build runner；没有 `build.zig` 的文件按单文件处理。
- **大型代码库上也快**：在 Zig 编译器源码（54 万行加标准库）上，hover 与补全在几毫秒内返回。

## Zig 版本

Zig **0.17.0**。请用项目所用的同一个 Zig 编译 zig-analyzer。

`PATH` 中（或 `zig.path` 指定）的 `zig` 版本不同时，带 `build.zig` 的项目不加载：没有编译器诊断，命名模块（依赖包、构建选项）的 import 无法解析。live 诊断改用 `zig ast-check`。

## 功能

- **诊断**
  - 编辑时：语法与 AstGen 错误。
  - 保存时：构建给出的编译错误（默认 `check` step，可用 `diagnostics.steps` 指定），附带 note 与引用链。
  - 非活动代码（默认关闭，`diagnostics.inactive_code`）：当前构建配置下 comptime 已知不编译的代码标为 unnecessary。
- **导航**：跳转到定义 / 声明 / 类型定义，查找引用，文档内高亮，文档符号，工作区符号。
- **编辑**
  - 补全，选中函数时给出签名与文档，包括带官方文档的内置函数。
  - hover，参数提示。
  - inlay hints：推导出的类型，结构体与 union 初始化中字段的类型，形参名（包括实参容易弄混的内置函数）；只有一个实参的调用，以及实参已经带着形参名的（包括套在 `&`、`.*`、`.?`、`try` 里的）不显示形参名。
  - 语义着色（full、delta、range），标出未使用的绑定；可以只发需要语义分析的 token（`semantic_tokens.mode = .partial`，叠加在编辑器的语法高亮之上），以及为容器级的 `var` 标上 `global`。
- **重构**：重命名（支持 prepare）；代码操作：
  - 丢弃未使用的名字，或删除多余的丢弃；
  - 删除未使用的函数参数，同时删除工作区中每处调用对应的实参；有无法更新的用法时拒绝并说明原因；
  - 把从未修改的局部 `var` 改为 `const`；
  - 补上 switch 缺少的分支；
  - 补上结构体初始化缺少的字段；
  - 把表达式提取为局部常量；
  - 普通字符串与多行字符串互相转换，字节值不变；
  - 整理 import：把顶层的 `@import` 声明（以及由它们派生的声明）按 std、依赖模块、文件分组排序；自动导入按同样的顺序插入新的 import。
- **格式化**：与 `zig fmt` 逐字一致，支持 `.zig` 与 `.zon`。
- **结构**：折叠，选择范围。
- **命名检查**（默认关闭）：依据 Zig 风格指南的 [Names](https://ziglang.org/documentation/0.17.0/#Names) 一节，按声明实际表示的东西（类型、函数、值）判断，并提供改名修复；改名不安全时拒绝。

## 安装

```sh
git clone https://github.com/jinzhongjia/zig-analyzer
cd zig-analyzer
zig build -Doptimize=ReleaseSafe
```

可执行文件为 `zig-out/bin/zig-analyzer`，放进 `PATH`，或在编辑器中指定它的路径。

## 编辑器配置

任何 LSP 客户端都可以使用：通过 stdio 运行 `zig-analyzer`。

Neovim 0.11+：

```lua
vim.lsp.config('zig_analyzer', {
  cmd = { 'zig-analyzer' },
  filetypes = { 'zig', 'zon' },
  -- 按目录项的实际名字匹配。`root_markers = { 'build.zig', '.git' }` 按路径查找，在大小写不敏感的
  -- 文件系统（macOS 与 Windows 的默认）上也会找到标准库的 `std/Build.zig`，把标准库目录当作工作区根目录
  root_dir = function(bufnr, on_dir)
    on_dir(vim.fs.root(bufnr, function(name) return name == 'build.zig' or name == '.git' end))
  end,
  settings = { ['zig-analyzer'] = {} },
})
vim.lsp.enable('zig_analyzer')
```

## 配置

编辑器的配置来自 `initializationOptions` 与 `workspace/configuration` 的 `zig-analyzer` 一节，各项都可以省略。

项目根目录的 `zig-analyzer.zon` 用于团队共享项目的配置（构建参数、诊断的 step、命名检查、import 的排列），优先于编辑器的配置。

[`zig-analyzer.default.zon`](zig-analyzer.default.zon) 列出了全部配置项、默认值与作用（英文注释）。可以复制为 `zig-analyzer.zon` 使用；只能在编辑器中设置的项写在注释里。

## 文档

[`docs/design.md`](docs/design.md)：架构、性能目标与当前测量结果、正确性的验证方式。
