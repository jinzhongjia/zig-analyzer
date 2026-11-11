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

## 编辑器支持

| 编辑器 | 集成方式 |
| --- | --- |
| VS Code | 扩展，见 [`editors/vscode`](editors/vscode) |
| Zed | 扩展，见 [`editors/zed`](editors/zed)（需同时安装 Zig 扩展） |
| Neovim 0.12+ | 插件 [zig-analyzer.nvim](https://github.com/jinzhongjia/zig-analyzer.nvim)，在 [`editors/nvim`](editors/nvim) 中开发 |
| Vim | 插件 [zig-analyzer.vim](https://github.com/jinzhongjia/zig-analyzer.vim)，在 [`editors/vim`](editors/vim) 中开发，支持 yegappan/lsp 和 vim-lsp |

不使用 Neovim 插件时，Neovim 0.12+ 只需：

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

## 安装

每个 [release](https://github.com/jinzhongjia/zig-analyzer/releases) 都为每个平台（Linux、macOS、Windows 的 x86_64 和 aarch64）提供两种构建：

| 构建 | 用途 |
| --- | --- |
| `ReleaseSafe` | 推荐。保留安全检查：出现 bug 时服务器停止并在日志里留下栈回溯，而不是给出错误结果，编辑器会重启它。报告崩溃时请附上日志。 |
| `ReleaseFast` | 关闭安全检查，稍快。出现 bug 时可能给出错误结果，或没有栈回溯地崩溃。 |

把 `zig-analyzer`（Windows 上是 `zig-analyzer.exe`）放进 `PATH`，或在编辑器插件里配置它的路径。

压缩包和 `SHA256SUMS` 用 [minisign](https://jedisct1.github.io/minisign/) 签名。用 [`minisign.pub`](minisign.pub) 里的公钥，以 `minisign` 或 [`minizign`](https://github.com/jedisct1/zig-minisign) 验证：

```sh
minisign -Vm zig-analyzer-<version>-<target>-ReleaseSafe.tar.gz -p minisign.pub
minizign -V -p minisign.pub -m zig-analyzer-<version>-<target>-ReleaseSafe.tar.gz
```

每个压缩包还带有构建来源证明（build provenance attestation），可证明它是本仓库的 release workflow 从打 tag 的 commit 构建的：

```sh
gh attestation verify zig-analyzer-<version>-<target>-ReleaseSafe.tar.gz --repo jinzhongjia/zig-analyzer
```

带后缀的版本（`0.2.0-rc.1`）是预发布版本。各版本的变化见 [`CHANGELOG.md`](CHANGELOG.md)。

## 开发

需要 Zig **0.17.0** 或 **0.17.1**。

```sh
zig build -Doptimize=ReleaseSafe  # 构建 zig-out/bin/zig-analyzer
zig build test                    # 运行不依赖外部工具的测试
zig build test-all                # 运行全部测试，包括会调用 PATH 中 zig 的测试
```

配置项见 [`zig-analyzer.default.zon`](zig-analyzer.default.zon)，设计说明见 [`docs/design.md`](docs/design.md)。

## 许可证

[MIT](LICENSE)
