# zig-analyzer

[English](README.md) | 简体中文

基于增量查询引擎的 Zig 语言服务器（LSP）。

## 特性

- **诊断**：错误只来自 Zig 本身，输入时使用进程内 AstGen，保存时使用 `zig build`。可选标记未生效的代码。
- **Comptime 求值**：对泛型和类型构造函数进行真实求值，并用调用处的实例分析泛型函数体。
- **构建系统集成**：项目模型来自官方构建系统协议。没有 `build.zig` 的文件使用单文件模式。
- **导航**：跳转到定义 / 声明 / 类型定义、查找引用、文档高亮、文档符号和工作区符号。
- **编辑**：支持自动导入和代码片段的补全、悬停提示、签名帮助、内联提示和语义 token。
- **重构**：重命名，以及多种代码操作：处理未使用的名字、参数和捕获，`var` 改 `const`，补全缺失的 switch 分支和结构体字段，提取常量，转换字符串字面量，整理导入。
- **格式化**：与 `zig fmt` 结果一致，支持 `.zig` 和 `.zon`。
- **ZON 文件**：所有 `.zon` 文件都有高亮、格式化和错误诊断；提供大纲；为带结果类型导入的文件和 `build.zig.zon` 提供补全、跳转和内联提示；`zig-analyzer.zon` 提供配置补全和配置说明。
- **结构**：折叠范围和选择范围。
- **命名检查**（需手动开启）：依据 Zig 风格指南的 [Names](https://ziglang.org/documentation/0.17.1/#Names) 一节给出提示，并提供安全的重命名修复。

## Neovim 配置

Neovim 0.12+：

```lua
vim.lsp.config('zig_analyzer', {
  cmd = { 'zig-analyzer' },
  filetypes = { 'zig', 'zon' },
  -- 按目录项的实际名字匹配。`root_markers = { 'build.zig', '.git' }` 检查的是路径，
  -- 在大小写不敏感的文件系统上（macOS 和 Windows 默认如此）还会找到标准库的
  -- `std/Build.zig`，从而把标准库目录当成工作区根目录。
  root_dir = function(bufnr, on_dir)
    on_dir(vim.fs.root(bufnr, function(name) return name == 'build.zig' or name == '.git' end))
  end,
  settings = { ['zig-analyzer'] = {} },
})
vim.lsp.enable('zig_analyzer')
```

## 开发

需要 Zig **0.17.0** 或 **0.17.1**。

```sh
zig build -Doptimize=ReleaseSafe  # 构建 zig-out/bin/zig-analyzer
zig build test                    # 运行不依赖外部工具的测试
zig build test-all                # 运行全部测试，包括会调用 PATH 中 zig 的测试
```

配置项见 [`zig-analyzer.default.zon`](zig-analyzer.default.zon)，设计说明见 [`docs/design.md`](docs/design.md)。
