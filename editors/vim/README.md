# zig-analyzer for Vim

Registers the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) language server with
[yegappan/lsp](https://github.com/yegappan/lsp) or
[vim-lsp](https://github.com/prabirshrestha/vim-lsp), whichever is loaded, and adds `:ZigAnalyzer`
for the server's own requests. Vim recognizes `.zig` and `.zon` files as `zig` by itself.

## Installation

The plugin is the `editors/vim` directory of the repository; install it together with one LSP
client, [yegappan/lsp](https://github.com/yegappan/lsp) (Vim 9) or
[vim-lsp](https://github.com/prabirshrestha/vim-lsp). You also need `zig-analyzer` in `PATH` (or
`g:zig_analyzer_cmd`) and Zig 0.17.0 or 0.17.1. The examples use yegappan/lsp; for vim-lsp, use
`prabirshrestha/vim-lsp` instead.

### vim-plug

```vim
call plug#begin()
Plug 'yegappan/lsp'
Plug 'jinzhongjia/zig-analyzer', { 'rtp': 'editors/vim' }
call plug#end()
```

Then `:PlugInstall`.

### Vundle

```vim
call vundle#begin()
Plugin 'VundleVim/Vundle.vim'
Plugin 'yegappan/lsp'
Plugin 'jinzhongjia/zig-analyzer', { 'rtp': 'editors/vim/' }
call vundle#end()
filetype plugin indent on
```

Then `:PluginInstall`.

### dein.vim

```vim
call dein#begin('~/.cache/dein')
call dein#add('yegappan/lsp')
call dein#add('jinzhongjia/zig-analyzer', { 'rtp': 'editors/vim' })
call dein#end()
filetype plugin indent on
```

Then `:call dein#install()`.

### Vim packages (no plugin manager)

```sh
git clone https://github.com/yegappan/lsp ~/.vim/pack/lsp/start/lsp
git clone https://github.com/jinzhongjia/zig-analyzer ~/.vim/pack/zig-analyzer/opt/zig-analyzer
mkdir -p ~/.vim/pack/zig-analyzer/start
ln -s ../opt/zig-analyzer/editors/vim ~/.vim/pack/zig-analyzer/start/zig-analyzer
```

The repository goes under `opt/`, so only its `editors/vim` directory is loaded at startup.

## Settings

```vim
let g:zig_analyzer_settings = {
      \ 'build': {'args': ['-Dtarget=aarch64-linux']},
      \ }
```

See `:help zig_analyzer`.

## Test

The smoke test opens a copy of `editors/test-project` and needs Zig 0.17 in `PATH`:

```sh
ZIG_ANALYZER=/path/to/zig-analyzer ZA_CLIENT=yegappan ZA_CLIENT_DIR=/path/to/yegappan-lsp \
  ZA_RESULT=/tmp/result.txt vim -N -u NONE -i NONE --not-a-term -S test/smoke.vim; cat /tmp/result.txt
```

`ZA_CLIENT=vimlsp` with `ZA_CLIENT_DIR` pointing at vim-lsp tests the other client.
