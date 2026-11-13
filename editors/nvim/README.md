# zig-analyzer.nvim

Neovim plugin for the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) Zig language
server: configures it with `vim.lsp.config` and adds `:ZigAnalyzer` for the server's own requests.
Requires Neovim 0.12+, the server (see below), and Zig 0.17.0 or 0.17.1.

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

## Server

`:ZigAnalyzer install` downloads the latest
[release](https://github.com/jinzhongjia/zig-analyzer/releases) for the system into
`stdpath('data')/zig-analyzer` and restarts the running servers with it
(`:ZigAnalyzer install v0.1.1 ReleaseFast` picks a release and build mode). It verifies the
release's minisign signature and the archive's SHA-256 first, and needs `curl` and `tar`. The
plugin downloads nothing on its own.

The server is `cmd` from `setup()` if set, else the installed release, else `zig-analyzer` in
`PATH`.

## Setup

```lua
require('zig-analyzer').setup({
  -- Any field of vim.lsp.Config, such as cmd = { '/path/to/zig-analyzer' }
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
Zig 0.17 in `PATH`; the install test installs fake releases signed with a temporary key and also
needs Node, `curl`, and `tar`.

```sh
cd editors/nvim
XDG_STATE_HOME=$(mktemp -d) ZIG_ANALYZER=/path/to/zig-analyzer nvim --headless --clean -u NONE -l test/smoke.lua
XDG_DATA_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d) ZIG_ANALYZER=/path/to/zig-analyzer nvim --headless --clean -u NONE -l test/install.lua
```
