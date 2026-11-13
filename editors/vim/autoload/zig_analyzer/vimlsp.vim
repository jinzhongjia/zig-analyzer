" Registration and requests through prabirshrestha/vim-lsp

function! zig_analyzer#vimlsp#register() abort
  call lsp#register_server({
        \ 'name': g:zig_analyzer#name,
        \ 'cmd': {server_info -> s:cmd()},
        \ 'allowlist': ['zig'],
        \ 'root_uri': {server_info -> s:root_uri()},
        \ 'initialization_options': zig_analyzer#settings(),
        \ 'workspace_config': function('zig_analyzer#workspace_config'),
        \ })
endfunction

" vim-lsp gets the command each time it starts the server, and starts none when it is empty
function! s:cmd() abort
  let l:cmd = zig_analyzer#cmd()
  if empty(l:cmd)
    call zig_analyzer#missing()
  endif
  return l:cmd
endfunction

function! s:root_uri() abort
  let l:root = zig_analyzer#root(lsp#utils#get_buffer_path())
  return empty(l:root) ? v:null : lsp#utils#path_to_uri(l:root)
endfunction

function! zig_analyzer#vimlsp#request(method, params, Callback) abort
  if lsp#get_server_status(g:zig_analyzer#name) !=# 'running'
    call a:Callback(v:null, {'message': 'zig-analyzer is not running'})
    return
  endif
  call lsp#send_request(g:zig_analyzer#name, {
        \ 'method': a:method,
        \ 'params': a:params,
        \ 'on_notification': function('s:on_response', [a:Callback]),
        \ })
endfunction

function! s:on_response(Callback, data) abort
  let l:response = get(a:data, 'response', {})
  if has_key(l:response, 'error')
    call a:Callback(v:null, l:response.error)
  elseif lsp#client#is_error(l:response)
    call a:Callback(v:null, {'message': lsp#client#error_message(l:response)})
  else
    call a:Callback(get(l:response, 'result', v:null), {})
  endif
endfunction

function! zig_analyzer#vimlsp#restart() abort
  call lsp#stop_server(g:zig_analyzer#name)
  " vim-lsp starts the server again for the next buffer it is opened for
  let l:buf = bufnr('%')
  call timer_start(500, {-> s:reopen(l:buf)})
endfunction

function! s:reopen(buf) abort
  if bufexists(a:buf) && bufnr('%') == a:buf
    doautocmd <nomodeline> lsp BufReadPost
  endif
endfunction

" After `:ZigAnalyzer install`: stops the running server, then starts the installed one for the
" Zig buffers in windows
function! zig_analyzer#vimlsp#installed() abort
  call lsp#stop_server(g:zig_analyzer#name)
  call s:start_when_stopped(100)
endfunction

function! s:start_when_stopped(tries) abort
  if index(['running', 'starting'], lsp#get_server_status(g:zig_analyzer#name)) >= 0 && a:tries > 0
    call timer_start(100, {-> s:start_when_stopped(a:tries - 1)})
    return
  endif
  for l:win in getwininfo()
    if getbufvar(l:win.bufnr, '&filetype') ==# 'zig'
      call win_execute(l:win.winid, 'call lsp#activate()')
    endif
  endfor
endfunction
