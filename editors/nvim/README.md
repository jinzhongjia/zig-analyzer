# zig-analyzer for Neovim

Configures the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) language server with
`vim.lsp.config` and adds `:ZigAnalyzer` for the server's own requests. Requires Neovim 0.12+.

## Installation

With `vim.pack` (or any plugin manager), from the `editors/nvim` directory of the repository:

```lua
vim.pack.add({ { src = 'https://github.com/jinzhongjia/zig-analyzer' } })
vim.opt.runtimepath:append(vim.fn.stdpath('data') .. '/site/pack/core/opt/zig-analyzer/editors/nvim')
```

Or point `runtimepath` at a local checkout: `vim.opt.runtimepath:append('/path/to/zig-analyzer/editors/nvim')`.

## Setup

```lua
require('zig-analyzer').setup({
  settings = {
    build = { args = { '-Dtarget=aarch64-linux' } },
  },
})
```

See `:help zig-analyzer` for the settings and commands, and `:checkhealth zig-analyzer`.

## Test

```sh
XDG_STATE_HOME=$(mktemp -d) ZIG_ANALYZER=/path/to/zig-analyzer nvim --headless --clean -u NONE -l test/smoke.lua
```
