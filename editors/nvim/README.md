# zig-analyzer.nvim

Neovim plugin for the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) Zig language
server: configures it with `vim.lsp.config` and adds `:ZigAnalyzer` for the server's own requests.
Requires Neovim 0.12+, `zig-analyzer` in `PATH` (or `cmd` in `setup()`), and Zig 0.17.0 or 0.17.1.

This repository is a read-only mirror of
[`editors/nvim`](https://github.com/jinzhongjia/zig-analyzer/tree/main/editors/nvim) in the
zig-analyzer repository, where the plugin is developed and tested: report issues and send pull
requests there.

## Installation

### vim.pack (built in)

```lua
vim.pack.add({ 'https://github.com/jinzhongjia/zig-analyzer.nvim' })
require('zig-analyzer').setup()
```

### lazy.nvim

```lua
{
  'jinzhongjia/zig-analyzer.nvim',
  ft = 'zig',
  opts = {
    -- settings = { build = { args = { '-Dtarget=aarch64-linux' } } },
  },
}
```

`ft = 'zig'` loads it when the first Zig or ZON file opens; `opts` is passed to `setup()`.

## Setup

```lua
require('zig-analyzer').setup({
  -- Any field of vim.lsp.Config; cmd defaults to { 'zig-analyzer' }
  settings = {
    build = { args = { '-Dtarget=aarch64-linux' } },
  },
})
```

`settings` holds the options of
[`zig-analyzer.default.zon`](https://github.com/jinzhongjia/zig-analyzer/blob/main/zig-analyzer.default.zon)
as a Lua table. Without `setup()`, `vim.lsp.enable('zig_analyzer')` uses the configuration in
`lsp/zig_analyzer.lua`.

See `:help zig-analyzer` for the settings and commands, and `:checkhealth zig-analyzer`.

## Test

From the zig-analyzer repository: the smoke test opens a copy of `editors/test-project` and needs
Zig 0.17 in `PATH`.

```sh
cd editors/nvim
XDG_STATE_HOME=$(mktemp -d) ZIG_ANALYZER=/path/to/zig-analyzer nvim --headless --clean -u NONE -l test/smoke.lua
```
