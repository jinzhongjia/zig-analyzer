" Shared parts of the zig-analyzer plugin: options, root detection, and :ZigAnalyzer. The
" requests go through the LSP client the server was registered with (see `s:backend`).

" The name of the server in the LSP client
let g:zig_analyzer#name = 'zig-analyzer'

" 'yegappan' or 'vimlsp': the client the server is registered with
let s:backend = ''

function! zig_analyzer#cmd() abort
  let l:cmd = get(g:, 'zig_analyzer_cmd', ['zig-analyzer'])
  return type(l:cmd) == v:t_string ? [l:cmd] : l:cmd
endfunction

" The server settings: the options of `zig-analyzer.default.zon` as a dictionary
function! zig_analyzer#settings() abort
  let l:settings = get(g:, 'zig_analyzer_settings', {})
  return empty(l:settings) ? {} : l:settings
endfunction

" The answer to `workspace/configuration`: both clients look the `zig-analyzer` section up in it
function! zig_analyzer#workspace_config(...) abort
  return {'zig-analyzer': zig_analyzer#settings()}
endfunction

" The nearest directory above `path` that contains an entry named exactly `build.zig` or `.git`,
" and the name of that entry (`build.zig` when it has both); `['', '']` when there is none.
" Entries are compared by name, not looked up by path: on case-insensitive file systems a lookup
" of `build.zig` also finds the standard library's `std/Build.zig`.
function! s:find_root(path) abort
  let l:dir = fnamemodify(a:path, ':p:h')
  while 1
    try
      let l:names = readdir(l:dir)
    catch
      let l:names = []
    endtry
    for l:name in ['build.zig', '.git']
      if index(l:names, l:name) >= 0
        return [l:dir, l:name]
      endif
    endfor
    let l:parent = fnamemodify(l:dir, ':h')
    if l:parent ==# l:dir
      return ['', '']
    endif
    let l:dir = l:parent
  endwhile
endfunction

" The workspace root of `path` (see `s:find_root`), '' when there is none
function! zig_analyzer#root(path) abort
  return s:find_root(a:path)[0]
endfunction

" The entry that makes the workspace root of `path` a root, as an absolute path in the form of a
" yegappan/lsp `rootSearch` entry (a directory ends in `/`); '' when there is no root
function! zig_analyzer#root_entry(path) abort
  let [l:dir, l:name] = s:find_root(a:path)
  if empty(l:dir)
    return ''
  endif
  let l:entry = substitute(l:dir, '[/\\]$', '', '') . '/' . l:name
  return isdirectory(l:entry) ? l:entry . '/' : l:entry
endfunction

function! zig_analyzer#register(backend) abort
  if !empty(s:backend) || get(g:, 'zig_analyzer_enable', 1) == 0
    return
  endif
  if a:backend ==# 'yegappan'
    call zig_analyzer#yegappan#Register()
  else
    call zig_analyzer#vimlsp#register()
  endif
  let s:backend = a:backend
endfunction

" Registers with a client that is already loaded (yegappan/lsp first)
function! zig_analyzer#register_loaded() abort
  if exists('*g:LspAddServer')
    call zig_analyzer#register('yegappan')
  elseif exists('*lsp#register_server')
    call zig_analyzer#register('vimlsp')
  endif
endfunction

function! zig_analyzer#backend() abort
  return s:backend
endfunction

" Sends `method` to the server of the current buffer; `Callback(result, error)` gets the result,
" or an error dictionary with a `message`
function! zig_analyzer#request(method, params, Callback) abort
  if s:backend ==# 'yegappan'
    call zig_analyzer#yegappan#Request(a:method, a:params, a:Callback)
  elseif s:backend ==# 'vimlsp'
    call zig_analyzer#vimlsp#request(a:method, a:params, a:Callback)
  else
    call s:error('no LSP client: install yegappan/lsp or vim-lsp')
  endif
endfunction

function! s:document() abort
  let l:uri = s:backend ==# 'yegappan' ? zig_analyzer#yegappan#Uri(bufnr('%')) : lsp#utils#get_buffer_uri(bufnr('%'))
  return {'textDocument': {'uri': l:uri}}
endfunction

let s:commands = {
      \ 'status': ['status.json', 'zig-analyzer/status', 0, 'json'],
      \ 'fileStatus': ['file-status.json', 'zig-analyzer/fileStatus', 1, 'json'],
      \ 'syntaxTree': ['syntax-tree.txt', 'zig-analyzer/syntaxTree', 1, 'text'],
      \ 'moduleGraph': ['module-graph.json', 'zig-analyzer/moduleGraph', 0, 'json'],
      \ }

function! zig_analyzer#complete(lead, line, pos) abort
  let l:names = sort(keys(s:commands) + ['reloadWorkspace', 'restart'])
  return filter(l:names, 'v:val =~# "^" . a:lead')
endfunction

function! zig_analyzer#command(name) abort
  if a:name ==# 'reloadWorkspace'
    call zig_analyzer#request('zig-analyzer/reloadWorkspace', v:null, {r, e -> s:report(e)})
    return
  endif
  if a:name ==# 'restart'
    if s:backend ==# 'yegappan'
      call zig_analyzer#yegappan#Restart()
    elseif s:backend ==# 'vimlsp'
      call zig_analyzer#vimlsp#restart()
    endif
    return
  endif
  if !has_key(s:commands, a:name)
    call s:error('unknown subcommand: ' . a:name)
    return
  endif
  let [l:title, l:method, l:needs_file, l:filetype] = s:commands[a:name]
  if l:needs_file && &filetype !=# 'zig'
    call s:error('open a Zig or ZON file first')
    return
  endif
  let l:params = l:needs_file ? s:document() : v:null
  call zig_analyzer#request(l:method, l:params, function('s:show', [l:title, l:filetype]))
endfunction

function! s:report(error) abort
  if !empty(a:error)
    call s:error(get(a:error, 'message', string(a:error)))
  endif
endfunction

function! s:show(title, filetype, result, error) abort
  if !empty(a:error)
    call s:report(a:error)
    return
  endif
  if a:result is v:null || (type(a:result) == v:t_string && empty(a:result))
    call s:error('the file is not known to the server')
    return
  endif
  let l:lines = type(a:result) == v:t_string ? split(a:result, "\n") : split(zig_analyzer#json#pretty(a:result), "\n")
  botright vnew
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  silent! execute 'file zig-analyzer://' . a:title
  call setline(1, l:lines)
  let &l:filetype = a:filetype
  setlocal nomodifiable
endfunction

function! s:error(message) abort
  echohl ErrorMsg
  echomsg 'zig-analyzer: ' . a:message
  echohl None
endfunction
