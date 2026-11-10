" Smoke test against a real server, with yegappan/lsp or vim-lsp:
"   ZIG_ANALYZER=/path/to/zig-analyzer ZA_CLIENT=yegappan|vimlsp ZA_CLIENT_DIR=/path/to/client \
"     ZA_RESULT=/tmp/result.txt vim -N -u NONE -i NONE --not-a-term -S test/smoke.vim
" The results go to the file in ZA_RESULT; the exit code is 0 when every check passes.
set nocompatible
let s:root = expand('<sfile>:p:h:h')
let s:client = $ZA_CLIENT
execute 'set runtimepath^=' . fnameescape($ZA_CLIENT_DIR)
execute 'set runtimepath^=' . fnameescape(s:root)
filetype plugin on
syntax on

let g:zig_analyzer_cmd = [empty($ZIG_ANALYZER) ? 'zig-analyzer' : $ZIG_ANALYZER]
let g:zig_analyzer_settings = {'inlay_hints': {'parameters': v:false}}

runtime! plugin/*.vim
if s:client ==# 'yegappan'
  call LspOptionsSet({'autoComplete': v:false, 'showInlayHints': v:false})
endif
doautocmd VimEnter

let s:results = []
let s:failures = 0
function! s:check(cond, what) abort
  call add(s:results, (a:cond ? 'ok   ' : 'FAIL ') . s:client . ': ' . a:what)
  if !a:cond | let s:failures += 1 | endif
endfunction

function! s:wait(cond, ms) abort
  let l:deadline = reltimefloat(reltime()) + a:ms / 1000.0
  while !eval(a:cond) && reltimefloat(reltime()) < l:deadline
    sleep 50m
  endwhile
  return eval(a:cond)
endfunction

let s:dir = tempname()
call mkdir(s:dir . '/.git', 'p')
call writefile([
      \ 'const std = @import("std");',
      \ '',
      \ 'pub fn add(a: u32, b: u32) u32 {',
      \ '    return a + b;',
      \ '}',
      \ '',
      \ 'pub fn main() void {',
      \ '    const x = add(1, 2);',
      \ '    std.debug.print("{}\n", .{x});',
      \ '}',
      \ ], s:dir . '/main.zig')
execute 'edit ' . fnameescape(s:dir . '/main.zig')
call s:check(&filetype ==# 'zig', 'filetype is zig')
call s:check(zig_analyzer#backend() ==# s:client, 'registered with ' . zig_analyzer#backend())

let s:reply = {}
function! s:on_reply(result, error) abort
  let s:reply = {'result': a:result, 'error': a:error}
endfunction
function! s:request(method, params) abort
  let s:reply = {}
  call zig_analyzer#request(a:method, a:params, function('s:on_reply'))
  call s:wait('!empty(s:reply)', 30000)
  return s:reply
endfunction

" The server is running once a request gets through
let s:started = s:wait('!empty(s:request("zig-analyzer/waitIdle", v:null)) && empty(s:reply.error)', 30000)
call s:check(s:started, 'server running')

let s:uri = s:client ==# 'yegappan' ? zig_analyzer#yegappan#Uri(bufnr('%')) : lsp#utils#get_buffer_uri(bufnr('%'))
let s:hover = s:request('textDocument/hover', {'textDocument': {'uri': s:uri}, 'position': {'line': 7, 'character': 15}})
call s:check(get(get(get(s:hover, 'result', {}), 'contents', {}), 'value', '') =~# 'fn add(a: u32, b: u32) u32', 'hover')

let s:hints = s:request('textDocument/inlayHint', {'textDocument': {'uri': s:uri}, 'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 10, 'character': 0}}})
let s:labels = map(copy(get(s:hints, 'result', [])), {_, h -> type(h.label) == v:t_string ? h.label : join(map(copy(h.label), 'v:val.value'), '')})
call s:check(join(s:labels) =~# 'u32', 'type hint: ' . join(s:labels))
call s:check(join(s:labels) !~# 'a:', 'settings reach the server (no parameter hints)')

let s:file_status = s:request('zig-analyzer/fileStatus', {'textDocument': {'uri': s:uri}})
call s:check(type(get(s:file_status, 'result')) == v:t_dict, 'fileStatus')

ZigAnalyzer syntaxTree
call s:wait('bufname("%") =~# "syntax-tree"', 10000)
call s:check(getline(1) =~# '^source_file@', ':ZigAnalyzer syntaxTree')
close

ZigAnalyzer status
call s:wait('bufname("%") =~# "status.json"', 10000)
call s:check(&filetype ==# 'json' && join(getline(1, '$')) =~# '"revision"', ':ZigAnalyzer status')
close

" The server process is replaced: compare the pids running the server command
function! s:server_pids() abort
  return sort(split(system('pgrep -f -x ' . shellescape(join(g:zig_analyzer_cmd)))))
endfunction
let s:pids_before = s:server_pids()
ZigAnalyzer restart
let s:restarted = s:wait('!empty(s:server_pids()) && s:server_pids() != s:pids_before', 30000)
      \ && s:wait('!empty(s:request("zig-analyzer/waitIdle", v:null)) && empty(s:reply.error)', 30000)
call s:check(s:restarted, ':ZigAnalyzer restart')

call writefile(s:results, $ZA_RESULT)
call delete(s:dir, 'rf')
execute s:failures == 0 ? 'qa!' : 'cquit!'
