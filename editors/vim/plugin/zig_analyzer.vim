" zig-analyzer: registers the zig-analyzer language server with yegappan/lsp or vim-lsp, and adds
" :ZigAnalyzer for the server's own requests.

if exists('g:loaded_zig_analyzer')
  finish
endif
let g:loaded_zig_analyzer = 1

if !exists('g:zig_analyzer_check_updates')
  let g:zig_analyzer_check_updates = 1
endif

augroup zig_analyzer
  autocmd!
  " yegappan/lsp
  autocmd User LspSetup call zig_analyzer#register('yegappan')
  " vim-lsp
  autocmd User lsp_setup call zig_analyzer#register('vimlsp')
  " Either client may have loaded before this plugin, after its setup event
  autocmd VimEnter * call zig_analyzer#register_loaded()
  " The update check: after startup, or after the plugin is loaded lazily
  autocmd VimEnter * call zig_analyzer#update#schedule()
  autocmd FileType zig call zig_analyzer#update#schedule()
augroup END

command! -nargs=+ -complete=customlist,zig_analyzer#complete ZigAnalyzer call zig_analyzer#command(<f-args>)
