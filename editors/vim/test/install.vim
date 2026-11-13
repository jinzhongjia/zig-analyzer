" Test of `:ZigAnalyzer install`, with yegappan/lsp or vim-lsp, on fake releases in a local
" directory signed by test/release.mjs:
"   ZIG_ANALYZER=/path/to/zig-analyzer ZA_CLIENT=yegappan|vimlsp ZA_CLIENT_DIR=/path/to/client \
"     ZA_RESULT=/tmp/result.txt vim -N -u NONE -i NONE --not-a-term -S test/install.vim
" Needs node, minisign, curl, tar, and sha256sum or shasum in PATH (macOS or Linux). The
" results go to the file in ZA_RESULT; the exit code is 0 when every check passes.
set nocompatible
" The messages of the installs would stop at the hit-enter and more prompts, waiting for a key
set messagesopt=wait:0,history:500
set nomore
let s:root = expand('<sfile>:p:h:h')
let s:client = $ZA_CLIENT
execute 'set runtimepath^=' . fnameescape($ZA_CLIENT_DIR)
execute 'set runtimepath^=' . fnameescape(s:root)
filetype plugin on

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
function! s:sh(...) abort
  let l:out = system(join(map(copy(a:000), 'shellescape(v:val)')))
  if v:shell_error
    throw 'failed: ' . join(a:000) . ': ' . l:out
  endif
  return trim(l:out)
endfunction
function! s:finish() abort
  call writefile(s:results + split(execute('messages'), "\n"), $ZA_RESULT)
  call delete(s:tmp, 'rf')
  execute s:failures == 0 ? 'qa!' : 'cquit!'
endfunction

let s:server = exepath(empty($ZIG_ANALYZER) ? 'zig-analyzer' : $ZIG_ANALYZER)
let s:tmp = resolve(tempname())
call mkdir(s:tmp, 'p')
if empty(s:server) || !executable('node') || !executable('minisign')
  call s:check(0, 'ZIG_ANALYZER is a zig-analyzer executable, and node and minisign are installed')
  call s:finish()
endif

" The release key, on the files of the v0.1.1 release
let s:key = g:zig_analyzer#install#public_key
let s:fixtures = s:root . '/test/fixtures'
call system(join(map(['minisign', '-V', '-Q', '-P', s:key, '-x', s:fixtures . '/SHA256SUMS.minisig',
      \ '-m', s:fixtures . '/SHA256SUMS'], 'shellescape(v:val)')))
call s:check(v:shell_error == 0, 'the release key verifies the v0.1.1 release')
if filereadable(s:root . '/../../minisign.pub')
  call s:check(get(readfile(s:root . '/../../minisign.pub'), 1, '') ==# s:key, 'the key is that of minisign.pub')
endif

" No zig-analyzer in PATH, and installs in a temporary directory
let $PATH = join(filter(split($PATH, ':'), '!executable(v:val . "/zig-analyzer")'), ':')
let g:zig_analyzer_data_dir = s:tmp . '/data'
let s:data = zig_analyzer#install#dir()
call s:check(s:data ==# s:tmp . '/data', 'g:zig_analyzer_data_dir sets the install directory')
call s:check(zig_analyzer#cmd() == [], 'without an install and PATH entry there is no server')

" The install of every release target is found (`x86_64` has an underscore)
for s:t in ['x86_64-linux', 'aarch64-linux', 'x86_64-macos', 'aarch64-macos', 'x86_64-windows', 'aarch64-windows']
  for s:opt in g:zig_analyzer#install#optimize_modes
    let s:name = printf('zig-analyzer-v1.2.3-rc.1-%s-%s', s:t, s:opt)
    call mkdir(s:data . '/' . s:name, 'p')
    call s:sh('cp', s:server, s:data . '/' . s:name . '/zig-analyzer')
    call writefile([s:name], s:data . '/current')
    call s:check(zig_analyzer#install#installed()[1] ==# s:name, 'an install for ' . s:t . ' ' . s:opt . ' is found')
    call delete(s:data . '/' . s:name, 'rf')
  endfor
endfor
call delete(s:data . '/current')
call s:check(zig_analyzer#install#installed() == ['', ''], 'without an install none is found')

" Fake releases
let s:keyfile = s:tmp . '/key.pem'
let g:zig_analyzer#install#public_key = s:sh('node', s:root . '/test/release.mjs', 'key', s:keyfile)
call s:sh('node', s:root . '/test/release.mjs', 'key', s:tmp . '/other.pem')
let s:target = zig_analyzer#install#target()
call s:check(s:target =~# '^\(x86_64\|aarch64\)-\(linux\|macos\)$', 'the release target is ' . s:target)
let s:releases = s:tmp . '/releases'
let g:zig_analyzer#install#releases = 'file://' . s:releases

" Writes the release `tag` to releases/download/<tag> and, with `latest`, to releases/latest/download
function! s:release(tag, opts) abort
  let l:dir = s:releases . '/download/' . a:tag
  call mkdir(l:dir, 'p')
  for l:opt in get(a:opts, 'optimize', ['ReleaseSafe', 'ReleaseFast'])
    let l:name = printf('zig-analyzer-%s-%s-%s', a:tag, s:target, l:opt)
    call mkdir(s:tmp . '/stage/' . l:name, 'p')
    call s:sh('cp', s:server, s:tmp . '/stage/' . l:name . '/zig-analyzer')
    call s:sh('tar', '-czf', l:dir . '/' . l:name . '.tar.gz', '-C', s:tmp . '/stage', l:name)
  endfor
  call s:sh('node', s:root . '/test/release.mjs', 'sign', get(a:opts, 'key', s:keyfile), l:dir,
        \ 'zig-analyzer ' . get(a:opts, 'comment', a:tag))
  if get(a:opts, 'latest', 0)
    call delete(s:releases . '/latest', 'rf')
    call mkdir(s:releases . '/latest', 'p')
    call s:sh('cp', '-R', l:dir, s:releases . '/latest/download')
  endif
  return l:dir
endfunction

" Runs an install to its end; returns its error ('' on success)
function! s:on_done(error, exe) abort
  let s:done = 1
  let s:error = a:error
endfunction
function! s:run(opts) abort
  let s:done = 0
  let s:error = ''
  call zig_analyzer#install#install(extend(copy(a:opts), {'on_done': function('s:on_done')}))
  return s:wait('s:done', 120000) ? s:error : 'timed out'
endfunction
function! s:leftovers() abort
  return !empty(filter(readdir(s:data), 'v:val =~# "^\\.tmp"'))
endfunction
function! s:said(pattern) abort
  return execute('messages') =~# a:pattern
endfunction

" The command lines of the server processes that Vim runs
function! s:servers() abort
  let l:servers = []
  for l:pid in split(system('pgrep -P ' . getpid()))
    let l:cmd = trim(system('ps -o command= -p ' . l:pid))
    if l:cmd =~# 'zig-analyzer'
      call add(l:servers, l:cmd)
    endif
  endfor
  return l:servers
endfunction
" Waits until Vim runs one server, `exe`
function! s:runs(exe) abort
  let s:expected = [a:exe]
  if s:wait('s:servers() == s:expected', 30000)
    return 1
  endif
  call add(s:results, '     servers: ' . string(s:servers()))
  return 0
endfunction

let g:zig_analyzer_settings = {'build': {'enable': v:false}}
runtime! plugin/*.vim
if s:client ==# 'yegappan'
  call LspOptionsSet({'autoComplete': v:false, 'showInlayHints': v:false})
endif
doautocmd VimEnter
call s:check(zig_analyzer#backend() ==# s:client, 'registered with ' . zig_analyzer#backend())

let s:project = s:tmp . '/project'
call mkdir(s:project, 'p')
call s:sh('cp', '-R', s:root . '/../test-project/.', s:project)
messages clear
execute 'edit ' . fnameescape(s:project . '/src/main.zig')
call s:check(s:wait('s:said("not installed: run `:ZigAnalyzer install`")', 5000),
      \ 'without a server, opening a Zig file says how to install one')
call s:check(s:servers() == [], 'without a server none runs')

" Rejected installs leave nothing installed
call s:release('v9.9.7', {'key': s:tmp . '/other.pem'})
call s:check(s:run({'version': 'v9.9.7'}) =~# 'does not verify with the release key', 'a release signed with another key is rejected')
call s:release('v9.9.6', {'comment': 'v9.9.5'})
call s:check(s:run({'version': 'v9.9.6'}) =~# 'signed for v9.9.5', 'a release signed for another tag is rejected')
let s:dir = s:release('v9.9.4', {'optimize': ['ReleaseSafe']})
call s:check(s:run({'version': 'v9.9.4', 'optimize': 'ReleaseFast'}) =~# 'has no zig-analyzer-v9.9.4-', 'a release without the archive is rejected')
call writefile(['x'], printf('%s/zig-analyzer-v9.9.4-%s-ReleaseSafe.tar.gz', s:dir, s:target), 'a')
call s:check(s:run({'version': 'v9.9.4'}) =~# 'SHA-256 does not match', 'an archive with another SHA-256 is rejected')
call s:check(s:run({'version': 'v9.9.3'}) =~# 'cannot download', 'a release that does not exist is rejected')
call s:check(s:run({'version': 'nightly'}) =~# 'is not a release tag', 'a version that is no tag is rejected')
call s:check(s:run({'optimize': 'Debug'}) =~# 'unknown optimize mode', 'an unknown optimize mode is rejected')
call s:check(zig_analyzer#install#installed() == ['', ''], 'rejected installs install nothing')
call s:check(!s:leftovers(), 'rejected installs leave no temporary directory')

" Installing starts the server, and installing another release restarts it with that one
call s:release('v9.9.8', {})
call s:release('v9.9.9', {'latest': 1})
call s:check(s:run({}) ==# '', 'the latest release installs')
let [s:exe, s:name] = zig_analyzer#install#installed()
call s:check(s:name ==# printf('zig-analyzer-v9.9.9-%s-ReleaseSafe', s:target), 'the latest release is installed')
call s:check(s:exe ==# printf('%s/%s/zig-analyzer', s:data, s:name), 'it is installed in the install directory')
call s:check(readfile(s:data . '/current') == [s:name], 'it is the current install')
call s:check(zig_analyzer#cmd() == [s:exe], 'the installed server is the server command')
call s:check(s:runs(s:exe), 'the installed server starts for the open Zig file')

ZigAnalyzer install v9.9.8 ReleaseFast
call s:wait('!zig_analyzer#install#busy()', 120000)
let [s:exe, s:name] = zig_analyzer#install#installed()
call s:check(s:name ==# printf('zig-analyzer-v9.9.8-%s-ReleaseFast', s:target), ':ZigAnalyzer install selects a release and mode')
call s:check(!isdirectory(printf('%s/zig-analyzer-v9.9.9-%s-ReleaseSafe', s:data, s:target)), 'the previous install is removed')
call s:check(s:runs(s:exe), 'the running server restarts with the new install')

" Installing the installed release again downloads nothing
call delete(printf('%s/download/v9.9.8/zig-analyzer-v9.9.8-%s-ReleaseFast.tar.gz', s:releases, s:target))
call s:check(s:run({'version': 'v9.9.8', 'optimize': 'ReleaseFast'}) ==# '', 'reinstalling the installed release needs no download')

let s:completion = getcompletion('ZigAnalyzer install ', 'cmdline')
call s:check(index(s:completion, 'ReleaseFast') >= 0 && index(s:completion, 'latest') >= 0, 'install arguments complete')
call s:check(index(getcompletion('ZigAnalyzer ins', 'cmdline'), 'install') >= 0, 'the install subcommand completes')

" Without minisign the signature is not checked, the rest is
let g:zig_analyzer_minisign = ''
messages clear
call s:check(s:run({'version': 'v9.9.6'}) =~# 'signed for v9.9.5', 'without minisign a release signed for another tag is rejected')
call s:check(s:run({'version': 'v9.9.8'}) ==# '', 'without minisign a release installs')
call s:check(s:said('g:zig_analyzer_minisign is empty, so the signature of SHA256SUMS is not checked'),
      \ 'with an empty g:zig_analyzer_minisign the install says that the signature is not checked')
let g:zig_analyzer_minisign = 'zig-analyzer-test-no-minisign'
call s:check(s:run({'version': 'v9.9.8', 'optimize': 'ReleaseFast'}) =~# 'g:zig_analyzer_minisign: `zig-analyzer-test-no-minisign` is not an executable',
      \ 'a configured minisign that is missing fails the install')
call s:check(zig_analyzer#install#installed()[1] ==# printf('zig-analyzer-v9.9.8-%s-ReleaseSafe', s:target),
      \ 'an install that fails for a missing minisign changes nothing')
unlet g:zig_analyzer_minisign
" A PATH with the tools of the install but not minisign (and `sh`, which is 'shell' when $SHELL is
" unset)
let s:path = $PATH
let s:tools = s:tmp . '/tools'
call mkdir(s:tools, 'p')
for s:tool in ['sh', 'curl', 'tar', 'sha256sum', 'shasum', 'uname']
  if executable(s:tool)
    call s:sh('ln', '-s', exepath(s:tool), s:tools . '/' . s:tool)
  endif
endfor
let $PATH = s:tools
call s:check(!executable('minisign'), 'minisign is not in the PATH of the test')
messages clear
call s:check(s:run({'version': 'v9.9.6'}) =~# 'signed for v9.9.5', 'when minisign is not installed a release signed for another tag is rejected')
call s:check(s:said('minisign is not installed, so the signature of SHA256SUMS is not checked'),
      \ 'when minisign is not installed the install says that the signature is not checked')
let $PATH = s:path

" A configured g:zig_analyzer_cmd stays in use
let g:zig_analyzer_cmd = [s:server]
call s:check(zig_analyzer#cmd() == [s:server], 'g:zig_analyzer_cmd comes before the installed server')
messages clear
call s:check(s:run({'version': 'v9.9.8'}) ==# '', 'install works with g:zig_analyzer_cmd set')
call s:check(s:said('stays in use'), 'install says that g:zig_analyzer_cmd stays in use')
unlet g:zig_analyzer_cmd

" The installed server comes before that of PATH
let s:exe = zig_analyzer#install#installed()[0]
let s:bin = s:tmp . '/bin'
call mkdir(s:bin, 'p')
call s:sh('ln', '-s', s:server, s:bin . '/zig-analyzer')
let $PATH = s:bin . ':' . $PATH
call s:check(zig_analyzer#cmd() == [s:exe], 'the installed server comes before that of PATH')
call delete(s:data, 'rf')
call s:check(zig_analyzer#cmd() == ['zig-analyzer'], 'without an install the server is that of PATH')

" The default install directory
unlet g:zig_analyzer_data_dir
let $XDG_DATA_HOME = s:tmp . '/xdg'
call s:check(zig_analyzer#install#dir() ==# s:tmp . '/xdg/vim/zig-analyzer', 'installs go to $XDG_DATA_HOME/vim/zig-analyzer')

call s:finish()
