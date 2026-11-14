" Smoke test against a real server, on a copy of editors/test-project, with yegappan/lsp or vim-lsp:
"   ZIG_ANALYZER=/path/to/zig-analyzer ZA_CLIENT=yegappan|vimlsp ZA_CLIENT_DIR=/path/to/client \
"     ZA_RESULT=/tmp/result.txt vim -N -u NONE -i NONE --not-a-term -S test/smoke.vim
" Needs Zig 0.17 in PATH (the project is loaded through `zig build`). The results go to the file in
" ZA_RESULT; the exit code is 0 when every check passes.
set nocompatible
let s:root = expand('<sfile>:p:h:h')
let s:client = $ZA_CLIENT
execute 'set runtimepath^=' . fnameescape($ZA_CLIENT_DIR)
execute 'set runtimepath^=' . fnameescape(s:root)
filetype plugin on
syntax on

let g:zig_analyzer_cmd = [empty($ZIG_ANALYZER) ? 'zig-analyzer' : $ZIG_ANALYZER]
let g:zig_analyzer_settings = {'inlay_hints': {'exclude_single_argument': v:false}}

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
  call writefile(s:results, $ZA_RESULT)
endfunction

function! s:wait(cond, ms) abort
  let l:deadline = reltimefloat(reltime()) + a:ms / 1000.0
  while !eval(a:cond) && reltimefloat(reltime()) < l:deadline
    sleep 50m
  endwhile
  return eval(a:cond)
endfunction

call s:check(zig_analyzer#backend() ==# s:client, 'registered with ' . zig_analyzer#backend())
" Without a client every request would only time out: stop, with the messages (such as errors
" loading the client) in the results
if zig_analyzer#backend() !=# s:client
  call writefile(s:results + split(execute('messages'), "\n"), $ZA_RESULT)
  cquit!
endif

let s:dir = resolve(tempname())
call mkdir(s:dir, 'p')
call system('cp -R ' . shellescape(s:root . '/../test-project') . '/. ' . shellescape(s:dir))
" Named like the standard library's `std/Build.zig`: on case-insensitive file systems a lookup of
" `build.zig` from `src` finds it, and the root must still be the project directory
call writefile(['pub const name = "Build";'], s:dir . '/src/Build.zig')

function! s:path(rel) abort
  return s:dir . '/' . a:rel
endfunction

function! s:uri(rel) abort
  return s:client ==# 'yegappan' ? zig_analyzer#yegappan#Uri(bufnr(s:path(a:rel))) : lsp#utils#path_to_uri(s:path(a:rel))
endfunction

" The position of `needle` in a file of the project, `delta` characters after its start
function! s:pos(rel, needle, ...) abort
  let l:lines = readfile(s:path(a:rel))
  for l:i in range(len(l:lines))
    let l:col = stridx(l:lines[l:i], a:needle)
    if l:col >= 0
      return {'line': l:i, 'character': l:col + (a:0 ? a:1 : 0)}
    endif
  endfor
  throw 'not found: ' . a:needle
endfunction

let s:reply = {}
function! s:on_reply(result, error) abort
  let s:reply = {'result': a:result, 'error': a:error}
endfunction
function! s:request(method, params) abort
  let s:reply = {}
  call zig_analyzer#request(a:method, a:params, function('s:on_reply'))
  call s:wait('!empty(s:reply)', 60000)
  return get(s:reply, 'result', v:null)
endfunction

" Whether the server answers `zig-analyzer/waitIdle` (once it has finished the pending work)
function! s:idle() abort
  call s:request('zig-analyzer/waitIdle', v:null)
  return !empty(s:reply) && empty(s:reply.error)
endfunction

" Opens a project file and waits until the server has it
function! s:open(rel) abort
  execute 'edit ' . fnameescape(s:path(a:rel))
  call s:wait('s:idle()', 60000)
endfunction

function! s:labels(hints) abort
  return map(copy(a:hints), {_, h -> type(h.label) == v:t_string ? h.label : join(map(copy(h.label), 'v:val.value'), '')})
endfunction

call s:open('src/main.zig')
let s:main = bufnr('%')
call s:check(&filetype ==# 'zig', 'filetype is zig')
if &filetype !=# 'zig'
  call writefile(s:results + split(execute('messages'), "\n"), $ZA_RESULT)
  cquit!
endif
call s:check(s:idle(), 'server running')

let s:doc = {'uri': s:uri('src/main.zig')}
let s:status = s:request('zig-analyzer/fileStatus', {'textDocument': s:doc})
call s:check(type(s:status) == v:t_dict && len(s:status.projects) == 1 && s:status.projects[0].root ==# s:dir && !empty(s:status.modules),
      \ 'the file belongs to the build.zig project')

let s:call = s:pos('src/main.zig', 'shapes.area(square)', 7)
let s:hover = s:request('textDocument/hover', {'textDocument': s:doc, 'position': s:call})
let s:hover_text = type(s:hover) == v:t_dict ? s:hover.contents.value : ''
call s:check(stridx(s:hover_text, 'fn area(s: Square) u32') >= 0 && stridx(s:hover_text, 'The area of a square.') >= 0,
      \ 'hover shows the signature and the doc comment')

let s:defs = s:request('textDocument/definition', {'textDocument': s:doc, 'position': s:call})
let s:def = type(s:defs) == v:t_list ? get(s:defs, 0, {}) : s:defs
let s:def_uri = get(s:def, 'uri', get(s:def, 'targetUri', ''))
let s:def_range = get(s:def, 'range', get(s:def, 'targetSelectionRange', {'start': {'line': -1}}))
call s:check(s:def_uri =~# 'src/shapes\.zig$' && s:def_range.start.line == s:pos('src/shapes.zig', 'pub fn area').line,
      \ 'definition in the other file')

let s:refs = s:request('textDocument/references', {'textDocument': s:doc, 'position': s:call, 'context': {'includeDeclaration': v:true}})
call s:check(type(s:refs) == v:t_list && len(s:refs) == 3, 'references: declaration and two calls')

call s:check(type(s:request('textDocument/prepareRename', {'textDocument': s:doc, 'position': s:call})) == v:t_dict, 'prepareRename')
let s:edit = s:request('textDocument/rename', {'textDocument': s:doc, 'position': s:call, 'newName': 'surface'})
let s:files = 0
let s:edits = 0
if type(s:edit) == v:t_dict
  for s:e in values(get(s:edit, 'changes', {}))
    let s:files += 1
    let s:edits += len(s:e)
  endfor
  for s:c in get(s:edit, 'documentChanges', [])
    let s:files += 1
    let s:edits += len(s:c.edits)
  endfor
endif
call s:check(s:files == 2 && s:edits == 3, printf('rename: 3 edits in 2 files (%d in %d)', s:edits, s:files))

let s:completion = s:request('textDocument/completion', {'textDocument': s:doc, 'position': s:call})
let s:items = type(s:completion) == v:t_dict ? s:completion.items : (type(s:completion) == v:t_list ? s:completion : [])
let s:names = map(copy(s:items), 'v:val.label')
call s:check(index(s:names, 'area') >= 0 && index(s:names, 'Square') >= 0, 'completion of the members of shapes')

let s:sig = s:request('textDocument/signatureHelp', {'textDocument': s:doc, 'position': s:pos('src/main.zig', 'shapes.area(square)', 12)})
call s:check(type(s:sig) == v:t_dict && stridx(s:sig.signatures[0].label, 'area(s: Square)') >= 0, 'signature help')

let s:hints = s:request('textDocument/inlayHint', {'textDocument': s:doc, 'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 20, 'character': 0}}})
let s:hint_text = join(s:labels(type(s:hints) == v:t_list ? s:hints : []))
call s:check(stridx(s:hint_text, ': u32') >= 0, 'type hint (' . s:hint_text . ')')
" Single-argument calls show no parameter names by default: this one comes from the settings
call s:check(stridx(s:hint_text, 's:') >= 0, 'parameter hint enabled by the settings')

let s:tokens = s:request('textDocument/semanticTokens/full', {'textDocument': s:doc})
call s:check(type(s:tokens) == v:t_dict && len(s:tokens.data) > 0 && len(s:tokens.data) % 5 == 0, 'semantic tokens')

call s:open('src/shapes.zig')
let s:symbols = s:request('textDocument/documentSymbol', {'textDocument': {'uri': s:uri('src/shapes.zig')}})
let s:by_name = {}
for s:s in (type(s:symbols) == v:t_list ? s:symbols : [])
  let s:by_name[s:s.name] = s:s
endfor
" Clients without hierarchical symbol support (vim-lsp) get a flat list, where `side` names its
" container
let s:side_in_square = has_key(s:by_name, 'Square') && get(get(get(s:by_name.Square, 'children', []), 0, {}), 'name', '') ==# 'side'
      \ || get(get(s:by_name, 'side', {}), 'containerName', '') ==# 'Square'
call s:check(has_key(s:by_name, 'area') && s:side_in_square, 'document symbols with their container')

let s:folds = s:request('textDocument/foldingRange', {'textDocument': {'uri': s:uri('src/shapes.zig')}})
call s:check(type(s:folds) == v:t_list && !empty(s:folds), 'folding ranges')

let s:ws = s:request('workspace/symbol', {'query': 'Square'})
call s:check(type(s:ws) == v:t_list && !empty(filter(copy(s:ws), {_, v -> v.name ==# 'Square' && v.location.uri =~# 'src/shapes\.zig$'})),
      \ 'workspace symbol')

call s:open('src/lint.zig')
let s:lint = bufnr('%')
function! s:diagnostics() abort
  if s:client ==# 'yegappan'
    return lsp#diag#GetDiagsForBuf(s:lint)
  endif
  let l:all = []
  for l:response in values(lsp#internal#diagnostics#state#_get_all_diagnostics_grouped_by_server_for_uri(s:uri('src/lint.zig')))
    call extend(l:all, get(l:response.params, 'diagnostics', []))
  endfor
  return l:all
endfunction
call s:wait('!empty(s:diagnostics())', 20000)
let s:diags = s:diagnostics()
call s:check(!empty(s:diags) && stridx(s:diags[0].message, 'unused local constant') >= 0, 'live diagnostic')

let s:unused = s:pos('src/lint.zig', 'unused')
let s:actions = s:request('textDocument/codeAction', {
      \ 'textDocument': {'uri': s:uri('src/lint.zig')},
      \ 'range': {'start': s:unused, 'end': s:unused},
      \ 'context': {'diagnostics': [], 'only': ['quickfix']},
      \ })
call s:check(type(s:actions) == v:t_list && !empty(s:actions), 'quick fix for the unused constant')

let s:fmt = s:request('textDocument/formatting', {'textDocument': {'uri': s:uri('src/lint.zig')}, 'options': {'tabSize': 4, 'insertSpaces': v:true}})
call s:check(type(s:fmt) == v:t_list && !empty(s:fmt), 'formatting')

call s:open('build.zig.zon')
call s:check(&filetype ==# 'zig', 'build.zig.zon is handled')
let s:zon_symbols = s:request('textDocument/documentSymbol', {'textDocument': {'uri': s:uri('build.zig.zon')}})
call s:check(type(s:zon_symbols) == v:t_list && !empty(filter(copy(s:zon_symbols), {_, v -> v.name ==# 'name' || v.name ==# '.name'})), 'ZON outline')
let s:zon_hover = s:request('textDocument/hover', {'textDocument': {'uri': s:uri('build.zig.zon')}, 'position': s:pos('build.zig.zon', '.paths', 2)})
call s:check(type(s:zon_hover) == v:t_dict, 'ZON hover on a manifest field')

execute 'buffer ' . s:main
ZigAnalyzer syntaxTree
call s:wait('bufname("%") =~# "syntax-tree"', 10000)
call s:check(getline(1) =~# '^source_file@', ':ZigAnalyzer syntaxTree')
" `<CR>` on the `std` identifier of `const std = ...` goes to it in the source
call search('^\s*identifier@\d\+\.\.\d\+ "std"$')
execute "normal \<CR>"
let s:std_pos = s:pos('src/main.zig', 'std')
call s:check(bufnr('%') == s:main && [line('.'), col('.')] == [s:std_pos.line + 1, s:std_pos.character + 1],
      \ ':ZigAnalyzer syntaxTree: <CR> goes to the source')
only

ZigAnalyzer moduleGraph
call s:wait('bufname("%") =~# "module-graph"', 10000)
call s:check(stridx(join(getline(1, '$')), fnamemodify(s:path('src/main.zig'), ':~:.')) >= 0, ':ZigAnalyzer moduleGraph lists the project root module')
close

ZigAnalyzer status
call s:wait('bufname("%") ==# "zig-analyzer://status"', 10000)
call s:check(getline(1) =~# '^Revision ', ':ZigAnalyzer status')
close

ZigAnalyzer fileStatus
call s:wait('bufname("%") =~# "file-status"', 10000)
call s:check(!empty(filter(getline(1, '$'), {_, l -> l =~# '^Projects \+' . escape(fnamemodify(s:dir, ':~:.'), '\.~')})), ':ZigAnalyzer fileStatus')
close

ZigAnalyzer reloadWorkspace
call s:request('zig-analyzer/waitIdle', v:null)
let s:status = s:request('zig-analyzer/fileStatus', {'textDocument': s:doc})
call s:check(type(s:status) == v:t_dict && len(s:status.projects) == 1, ':ZigAnalyzer reloadWorkspace reloads the project')

" The server process is replaced: compare the pids running the server command
function! s:server_pids() abort
  return sort(split(system('pgrep -f -x ' . shellescape(join(g:zig_analyzer_cmd)))))
endfunction
let s:pids_before = s:server_pids()
ZigAnalyzer restart
let s:restarted = s:wait('!empty(s:server_pids()) && s:server_pids() != s:pids_before', 30000)
      \ && s:wait('s:idle()', 30000)
call s:check(s:restarted, ':ZigAnalyzer restart')
let s:status = s:request('zig-analyzer/fileStatus', {'textDocument': s:doc})
call s:check(type(s:status) == v:t_dict && len(s:status.projects) == 1 && s:status.projects[0].root ==# s:dir,
      \ 'the restarted server has the project root')

call add(s:results, s:failures == 0 ? 'all checks passed' : s:failures . ' checks failed')
if s:failures > 0
  call extend(s:results, split(execute('messages'), "\n"))
endif
call writefile(s:results, $ZA_RESULT)
call delete(s:dir, 'rf')
execute s:failures == 0 ? 'qa!' : 'cquit!'
