# zig-analyzer for Vim

Registers the [zig-analyzer](https://github.com/jinzhongjia/zig-analyzer) language server with
[yegappan/lsp](https://github.com/yegappan/lsp) or
[vim-lsp](https://github.com/prabirshrestha/vim-lsp), whichever is loaded, and adds `:ZigAnalyzer`
for the server's own requests. Vim recognizes `.zig` and `.zon` files as `zig` by itself.

## Installation

Add this directory to `runtimepath` together with one of the clients, for example with vim-plug:

```vim
Plug 'yegappan/lsp'
Plug 'jinzhongjia/zig-analyzer', { 'rtp': 'editors/vim' }
```

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
