" Test of the update check against metadata files in a temporary directory (file:// URLs):
"   ZA_RESULT=/tmp/result.txt vim -N -u NONE -i NONE --not-a-term -S test/update.vim
" The results go to the file in ZA_RESULT; the exit code is 0 when every check passes.
set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)

let s:results = []
let s:failures = 0
function! s:check(cond, what) abort
  call add(s:results, (a:cond ? 'ok   ' : 'FAIL ') . a:what)
  if !a:cond | let s:failures += 1 | endif
  if exists('$ZA_RESULT') && !empty($ZA_RESULT)
    call writefile(s:results, $ZA_RESULT)
  endif
endfunction

let s:dir = tempname()
call mkdir(s:dir, 'p')

function! s:write(name, text) abort
  call writefile([a:text], s:dir . '/' . a:name)
endfunction

function! s:url(name) abort
  return 'file://' . s:dir . '/' . a:name
endfunction

let s:seen = []
function! s:notify(message) abort
  call add(s:seen, a:message)
endfunction

function! s:run(opts) abort
  let l:result = {}
  let l:opts = extend({'on_done': {tag, current -> extend(l:result, {'tag': tag, 'current': current})}}, a:opts)
  call zig_analyzer#update#check(l:opts)
  let l:deadline = reltimefloat(reltime()) + 5.0
  while empty(l:result) && reltimefloat(reltime()) < l:deadline
    sleep 50m
  endwhile
  return l:result
endfunction

" Compare as SemVer does, with the `v` prefix and build metadata of the release tags
let s:versions = [
      \ ['v0.2.0', '0.1.2', 1],
      \ ['0.1.10', '0.1.9', 1],
      \ ['0.1.2', '0.1.2+3.gabc1234', 0],
      \ ['v0.1.2', '0.1.2', 0],
      \ ['0.1.2', '0.1.2-dev+d8b0905', 1],
      \ ['0.1.2-rc.1', '0.1.2', -1],
      \ ['0.1.2-alpha', '0.1.2-alpha.1', -1],
      \ ['0.1.2-alpha.2', '0.1.2-alpha.10', -1],
      \ ['nightly', '0.1.2', -2],
      \ ]
for [x, y, want] in s:versions
  call s:check(zig_analyzer#update#compare(x, y) == want, printf('compare(%s, %s) is %s', x, y, want))
endfor

call s:write('newer.json', '{"schema":1,"latest":"v9.9.9","versions":[]}')
call s:write('equal.json', '{"schema":1,"latest":"v0.1.2","versions":[]}')
call s:write('schema.json', '{"schema":2,"latest":"v9.9.9","versions":[]}')
call s:write('tag.json', '{"schema":1,"latest":"nightly","versions":[]}')
call s:write('invalid.json', 'not json')

let s:seen = []
let s:result = s:run({'version': '0.1.2', 'url': s:url('newer.json'), 'force': 1, 'notify': function('s:notify')})
call s:check(!empty(s:result) && s:result.tag ==# 'v9.9.9' && len(s:seen) == 1 && s:seen[0] =~# 'v9\.9\.9',
      \ 'a newer release is reported')

let s:seen = []
let s:result = s:run({'version': '0.1.2', 'url': s:url('equal.json'), 'force': 1, 'notify': function('s:notify')})
call s:check(!empty(s:result) && s:result.tag ==# 'v0.1.2' && empty(s:seen), 'an equal release is not reported')

let s:seen = []
let s:result = s:run({'version': '0.1.2', 'url': s:url('newer.json'), 'notify': function('s:notify')})
call s:check(!empty(s:result) && empty(s:seen), 'a tag is reported once')

for name in ['schema.json', 'tag.json', 'invalid.json']
  let s:seen = []
  let s:result = s:run({'version': '0.1.2', 'url': s:url(name), 'force': 1, 'notify': function('s:notify')})
  call s:check(!empty(s:result) && s:result.tag ==# '' && empty(s:seen), name . ' is ignored')
endfor

let s:seen = []
let s:result = s:run({'version': '0.1.2', 'url': s:url('missing.json'), 'force': 1, 'notify': function('s:notify')})
call s:check(!empty(s:result) && s:result.tag ==# '' && empty(s:seen), 'a missing metadata file gives no update')

let s:seen = []
let s:result = s:run({'version': '0.1.2', 'url': s:url('newer.json'), 'force': 1, 'notify': function('s:notify')})
call s:check(!empty(s:result) && s:result.tag ==# 'v9.9.9' && len(s:seen) == 1, 'a forced check reports again')

call delete(s:dir, 'rf')
call add(s:results, s:failures == 0 ? 'all checks passed' : s:failures . ' checks failed')
if s:failures > 0
  call extend(s:results, split(execute('messages'), "\n"))
endif
if exists('$ZA_RESULT') && !empty($ZA_RESULT)
  call writefile(s:results, $ZA_RESULT)
endif
execute s:failures == 0 ? 'qa!' : 'cquit!'
