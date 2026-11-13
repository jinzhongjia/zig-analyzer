# zig-analyzer.vim

Vim plugin for the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) Zig language server:
registers it with [yegappan/lsp](https://github.com/yegappan/lsp) (Vim 9) or
[vim-lsp](https://github.com/prabirshrestha/vim-lsp), whichever is loaded, and adds `:ZigAnalyzer`
for the server's own requests. Vim recognizes `.zig` and `.zon` files as `zig` by itself. Requires
the server (see below) and Zig 0.17.0 or 0.17.1.

This repository is a read-only mirror of
[`editors/vim`](https://github.com/jinzhongjia/zig-analyzer/tree/main/editors/vim) in the
zig-analyzer repository, where the plugin is developed and tested: report issues and send pull
requests there.

## Installation

Install it together with one of the LSP clients. The examples use yegappan/lsp; for vim-lsp, use
`prabirshrestha/vim-lsp` instead.

### vim-plug

```vim
call plug#begin()
Plug 'yegappan/lsp'
Plug 'jinzhongjia/zig-analyzer.vim'
call plug#end()
```

Then `:PlugInstall`.

### Vundle

```vim
call vundle#begin()
Plugin 'VundleVim/Vundle.vim'
Plugin 'yegappan/lsp'
Plugin 'jinzhongjia/zig-analyzer.vim'
call vundle#end()
filetype plugin indent on
```

Then `:PluginInstall`.

### dein.vim

```vim
call dein#begin('~/.cache/dein')
call dein#add('yegappan/lsp')
call dein#add('jinzhongjia/zig-analyzer.vim')
call dein#end()
filetype plugin indent on
```

Then `:call dein#install()`.

### Vim packages (no plugin manager)

```sh
git clone https://github.com/yegappan/lsp ~/.vim/pack/plugins/start/lsp
git clone https://github.com/jinzhongjia/zig-analyzer.vim ~/.vim/pack/plugins/start/zig-analyzer.vim
```

## The server

The plugin runs `g:zig_analyzer_cmd` when it is set, else the release installed by
`:ZigAnalyzer install`, else `zig-analyzer` from `PATH`. It downloads nothing by itself:

```vim
:ZigAnalyzer install                    " the latest release, built with ReleaseSafe
:ZigAnalyzer install v0.1.1 ReleaseFast " a given release and optimize mode
```

installs a release from GitHub into `~/.local/share/vim/zig-analyzer` (`g:zig_analyzer_data_dir`)
and restarts the running server with it. The archive must have the SHA-256 listed in the
release's `SHA256SUMS`, and when [minisign](https://jedisct1.github.io/minisign/) is installed,
`SHA256SUMS` must be signed by the release key; without minisign the install warns that the
signature is not checked. Needs `curl`, `tar`, and `sha256sum` or `shasum` (`certutil` on Windows).

## Settings

```vim
let g:zig_analyzer_settings = {
      \ 'build': {'args': ['-Dtarget=aarch64-linux']},
      \ }
```

See `:help zig_analyzer`.

## Test

From the zig-analyzer repository: the smoke test opens a copy of `editors/test-project` and needs
Zig 0.17 in `PATH`.

```sh
cd editors/vim
ZIG_ANALYZER=/path/to/zig-analyzer ZA_CLIENT=yegappan ZA_CLIENT_DIR=/path/to/yegappan-lsp \
  ZA_RESULT=/tmp/result.txt vim -N -u NONE -i NONE --not-a-term -S test/smoke.vim; cat /tmp/result.txt
```

`ZA_CLIENT=vimlsp` with `ZA_CLIENT_DIR` pointing at vim-lsp tests the other client.
