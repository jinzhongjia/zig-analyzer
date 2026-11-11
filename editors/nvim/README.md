# zig-analyzer for Neovim

Configures the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) language server with
`vim.lsp.config` and adds `:ZigAnalyzer` for the server's own requests. Requires Neovim 0.12+.

## Installation

The plugin is the `editors/nvim` directory of the repository, so each plugin manager installs the
repository and adds that directory to `runtimepath`. You also need `zig-analyzer` in `PATH` (or
`cmd` in `setup()`) and Zig 0.17.0 or 0.17.1.

### vim.pack (built in, Neovim 0.12)

```lua
vim.pack.add({ 'https://github.com/jinzhongjia/zig-analyzer' }, {
  load = function(plugin)
    vim.opt.runtimepath:append(plugin.path .. '/editors/nvim')
  end,
})
require('zig-analyzer').setup()
```

### lazy.nvim

```lua
{
  'jinzhongjia/zig-analyzer',
  ft = 'zig',
  config = function(plugin)
    vim.opt.runtimepath:append(plugin.dir .. '/editors/nvim')
    require('zig-analyzer').setup({
      -- settings = { build = { args = { '-Dtarget=aarch64-linux' } } },
    })
  end,
}
```

`ft = 'zig'` loads it when the first Zig or ZON file opens; without it, it loads at startup.

### Local checkout

```lua
vim.opt.runtimepath:append('/path/to/zig-analyzer/editors/nvim')
require('zig-analyzer').setup()
```

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

The smoke test opens a copy of `editors/test-project` and needs Zig 0.17 in `PATH`:

```sh
XDG_STATE_HOME=$(mktemp -d) ZIG_ANALYZER=/path/to/zig-analyzer nvim --headless --clean -u NONE -l test/smoke.lua
```
