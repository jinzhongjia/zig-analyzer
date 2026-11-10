" zig-analyzer: registers the zig-analyzer language server with yegappan/lsp or vim-lsp, and adds
" :ZigAnalyzer for the server's own requests.

if exists('g:loaded_zig_analyzer')
  finish
endif
let g:loaded_zig_analyzer = 1

augroup zig_analyzer
  autocmd!
  " yegappan/lsp
  autocmd User LspSetup call zig_analyzer#register('yegappan')
  " vim-lsp
  autocmd User lsp_setup call zig_analyzer#register('vimlsp')
  " Either client may have loaded before this plugin, after its setup event
  autocmd VimEnter * call zig_analyzer#register_loaded()
augroup END

command! -nargs=1 -complete=customlist,zig_analyzer#complete ZigAnalyzer call zig_analyzer#command(<q-args>)
