" `:ZigAnalyzer install`: downloads a release of the server from GitHub into the data directory
" (`zig_analyzer#install#dir()`), after checking it. The archive must have the SHA-256 that the
" release's SHA256SUMS lists for it, and when minisign is installed, SHA256SUMS must carry a
" minisign signature by the release key below whose trusted comment names the release
" (`zig-analyzer <tag>`). Vim has no Ed25519 or BLAKE2b, so the signature needs minisign, and its
" sha256() takes no binary data, so the SHA-256 needs `sha256sum`, `shasum`, or (on Windows)
" `certutil`. Downloads need `curl` and unpacking `tar` (both ship with Windows 10 and later).

" Where the releases are downloaded from, and the release signing key (`minisign.pub` at the root
" of the zig-analyzer repository). Not set when they are already: the tests set them first.
if !has_key(g:, 'zig_analyzer#install#releases')
  let g:zig_analyzer#install#releases = 'https://github.com/jinzhongjia/zig-analyzer/releases'
endif
if !has_key(g:, 'zig_analyzer#install#public_key')
  let g:zig_analyzer#install#public_key = 'RWRbma3B4tRgvIsJxiSxTvwoOWB6wvqxTEDgWVaJk0XMSeW9THbHBVj+'
endif
let g:zig_analyzer#install#optimize_modes = ['ReleaseSafe', 'ReleaseFast']

let s:windows = has('win32')
let s:exe_name = s:windows ? 'zig-analyzer.exe' : 'zig-analyzer'
" The tar of Windows (bsdtar) extracts zip archives; another one earlier in PATH, such as the GNU
" tar of Git for Windows, may not
let s:tar = s:windows ? (empty($SystemRoot) ? 'C:\Windows' : $SystemRoot) . '\System32\tar.exe' : 'tar'
let s:busy = 0

" The directory installs go to: `g:zig_analyzer_data_dir`, else `vim/zig-analyzer` in
" `$XDG_DATA_HOME` (`~/.local/share` when unset), or in `%LOCALAPPDATA%` on Windows
function! zig_analyzer#install#dir() abort
  let l:dir = get(g:, 'zig_analyzer_data_dir', '')
  if empty(l:dir)
    if s:windows
      let l:dir = (empty($LOCALAPPDATA) ? expand('~/AppData/Local') : $LOCALAPPDATA) . '/vim/zig-analyzer'
    else
      let l:dir = (empty($XDG_DATA_HOME) ? expand('~/.local/share') : $XDG_DATA_HOME) . '/vim/zig-analyzer'
    endif
  endif
  return substitute(fnamemodify(expand(l:dir), ':p'), '[/\\]\+$', '', '')
endfunction

" The installed server executable and its release directory name; `['', '']` when there is none
function! zig_analyzer#install#installed() abort
  let l:current = zig_analyzer#install#dir() . '/current'
  if !filereadable(l:current)
    return ['', '']
  endif
  let l:release = trim(get(readfile(l:current, '', 1), 0, ''))
  " `zig-analyzer-<tag>-<arch>-<os>-<optimize>`; the arch may be `x86_64`
  if l:release !~# '^zig-analyzer-v[0-9A-Za-z._-]\+$'
    return ['', '']
  endif
  let l:exe = zig_analyzer#install#dir() . '/' . l:release . '/' . s:exe_name
  return executable(l:exe) ? [l:exe, l:release] : ['', '']
endfunction

" `<arch>-<os>` of the release archive for this system; '' when there is none
function! zig_analyzer#install#target() abort
  if s:windows
    let l:machine = empty($PROCESSOR_ARCHITEW6432) ? $PROCESSOR_ARCHITECTURE : $PROCESSOR_ARCHITEW6432
    let l:os = 'windows'
  else
    let l:machine = trim(system('uname -m'))
    let l:os = get({'Linux': 'linux', 'Darwin': 'macos'}, trim(system('uname -s')), '')
  endif
  let l:arch = get({'x86_64': 'x86_64', 'amd64': 'x86_64', 'AMD64': 'x86_64',
        \ 'arm64': 'aarch64', 'aarch64': 'aarch64', 'ARM64': 'aarch64'}, l:machine, '')
  return empty(l:arch) || empty(l:os) ? '' : l:arch . '-' . l:os
endfunction

function! zig_analyzer#install#busy() abort
  return s:busy
endfunction

" `:ZigAnalyzer install [<tag>|latest] [ReleaseSafe|ReleaseFast]`
function! zig_analyzer#install#command(args) abort
  let l:opts = {}
  for l:arg in a:args
    if index(g:zig_analyzer#install#optimize_modes, l:arg) >= 0
      let l:opts.optimize = l:arg
    elseif l:arg !=# 'latest'
      let l:opts.version = l:arg
    endif
  endfor
  call zig_analyzer#install#install(l:opts)
endfunction

" Installs a release: `opts.version` is a tag (`v0.1.1`; the latest release by default),
" `opts.optimize` `ReleaseSafe` (default) or `ReleaseFast`. `opts.on_done(error, exe)` is called
" when it ends, with an empty error on success.
function! zig_analyzer#install#install(...) abort
  let l:opts = get(a:000, 0, {})
  let l:s = {
        \ 'version': get(l:opts, 'version', ''),
        \ 'optimize': get(l:opts, 'optimize', 'ReleaseSafe'),
        \ 'on_done': get(l:opts, 'on_done', v:null),
        \ 'tmp': '',
        \ }
  if index(g:zig_analyzer#install#optimize_modes, l:s.optimize) < 0
    return s:reject(l:s, 'unknown optimize mode ' . l:s.optimize)
  endif
  if !empty(l:s.version) && l:s.version !~# '^v\d\+\.\d\+\.\d\+[0-9A-Za-z.-]*$'
    return s:reject(l:s, printf('"%s" is not a release tag (such as v0.1.1)', l:s.version))
  endif
  if s:busy
    return s:reject(l:s, 'an install is already running')
  endif
  let s:busy = 1
  call s:step(l:s, function('s:start'))
endfunction

" The steps of an install: each runs a process and continues in its callback. A step ends the
" install by throwing `zig-analyzer: <why>`.

function! s:start(s) abort
  let a:s.target = zig_analyzer#install#target()
  if empty(a:s.target)
    throw 'zig-analyzer: no release for this system: build zig-analyzer from source and set g:zig_analyzer_cmd'
  endif
  for l:tool in ['curl', s:tar]
    if !executable(l:tool)
      throw 'zig-analyzer: `' . l:tool . '` is not installed'
    endif
  endfor
  let a:s.hash_cmd = executable('sha256sum') ? ['sha256sum']
        \ : executable('shasum') ? ['shasum', '-a', '256']
        \ : s:windows && executable('certutil') ? ['certutil', '-hashfile'] : []
  if empty(a:s.hash_cmd)
    throw 'zig-analyzer: there is no `sha256sum` or `shasum` to check the SHA-256 of the archive with'
  endif
  " Without minisign in PATH the signature goes unchecked, with a warning; a minisign that is
  " configured but missing is a mistake that must not turn the check off
  let a:s.minisign = get(g:, 'zig_analyzer_minisign', 'minisign')
  if exists('g:zig_analyzer_minisign') && !empty(a:s.minisign) && !executable(a:s.minisign)
    throw printf('zig-analyzer: g:zig_analyzer_minisign: `%s` is not an executable (set it to '''' to install without checking the signature)', a:s.minisign)
  endif
  let a:s.signed = !empty(a:s.minisign) && executable(a:s.minisign)
  let a:s.dir = zig_analyzer#install#dir()
  call mkdir(a:s.dir, 'p')
  let a:s.tmp = printf('%s/.tmp-%d-%s', a:s.dir, getpid(), substitute(reltimestr(reltime()), '\D', '', 'g'))
  call mkdir(a:s.tmp, 'p')
  let l:releases = g:zig_analyzer#install#releases
  let a:s.base = empty(a:s.version) ? l:releases . '/latest/download' : l:releases . '/download/' . a:s.version
  if exists('g:zig_analyzer_cmd')
    call s:warn('g:zig_analyzer_cmd is set, so the server it names stays in use')
  endif
  call s:message(empty(a:s.version) ? 'looking up the latest release' : 'looking up ' . a:s.version)
  call s:fetch(a:s, a:s.base . '/SHA256SUMS', a:s.tmp . '/SHA256SUMS', function('s:fetch_signature'))
endfunction

function! s:fetch_signature(s, ...) abort
  call s:fetch(a:s, a:s.base . '/SHA256SUMS.minisig', a:s.tmp . '/SHA256SUMS.minisig', function('s:verify'))
endfunction

function! s:verify(s, ...) abort
  let l:sig = a:s.tmp . '/SHA256SUMS.minisig'
  if a:s.signed
    " -Q prints the trusted comment once the signature and the signature of the comment verify
    call s:exec(a:s, [a:s.minisign, '-V', '-Q', '-P', g:zig_analyzer#install#public_key,
          \ '-x', l:sig, '-m', a:s.tmp . '/SHA256SUMS'],
          \ function('s:verified'), 'SHA256SUMS: the signature does not verify with the release key')
  else
    call s:warn(empty(a:s.minisign)
          \ ? 'g:zig_analyzer_minisign is empty, so the signature of SHA256SUMS is not checked'
          \ : 'minisign is not installed, so the signature of SHA256SUMS is not checked: install minisign to check it')
    call s:verified(a:s, [matchstr(get(readfile(l:sig), 2, ''), '^trusted comment: \zs.*')])
  endif
endfunction

function! s:verified(s, out) abort
  let l:comment = substitute(get(a:out, 0, ''), '\r$', '', '')
  let a:s.tag = matchstr(l:comment, '^zig-analyzer \zsv\d\+\.\d\+\.\d\+[0-9A-Za-z.-]*$')
  if empty(a:s.tag)
    throw printf('zig-analyzer: SHA256SUMS: unexpected trusted comment "%s"', l:comment)
  endif
  if !empty(a:s.version) && a:s.tag !=# a:s.version
    throw printf('zig-analyzer: SHA256SUMS is signed for %s, not %s', a:s.tag, a:s.version)
  endif
  let a:s.release = printf('zig-analyzer-%s-%s-%s', a:s.tag, a:s.target, a:s.optimize)
  let a:s.archive = a:s.release . (s:windows ? '.zip' : '.tar.gz')
  let a:s.hash = ''
  for l:line in readfile(a:s.tmp . '/SHA256SUMS')
    let l:m = matchlist(substitute(l:line, '\r$', '', ''), '^\(\x\{64}\)  \(.\+\)$')
    if !empty(l:m) && l:m[2] ==# a:s.archive
      let a:s.hash = tolower(l:m[1])
    endif
  endfor
  if empty(a:s.hash)
    throw printf('zig-analyzer: %s has no %s', a:s.tag, a:s.archive)
  endif
  if zig_analyzer#install#installed()[1] ==# a:s.release
    call s:select(a:s)
    return
  endif
  call s:message('downloading ' . a:s.archive)
  " From the checked release: `latest` may have moved on since SHA256SUMS was downloaded
  let l:url = printf('%s/download/%s/%s', g:zig_analyzer#install#releases, a:s.tag, a:s.archive)
  call s:fetch(a:s, l:url, a:s.tmp . '/' . a:s.archive, function('s:hash'))
endfunction

function! s:hash(s, ...) abort
  let l:file = a:s.tmp . '/' . a:s.archive
  let l:cmd = a:s.hash_cmd[0] ==# 'certutil' ? a:s.hash_cmd + [l:file, 'SHA256'] : a:s.hash_cmd + [l:file]
  call s:exec(a:s, l:cmd, function('s:hashed'), 'cannot compute the SHA-256 of ' . a:s.archive)
endfunction

function! s:hashed(s, out) abort
  let l:hash = ''
  for l:line in a:out
    " sha256sum and shasum: `<hash>  <file>` (sha256sum starts it with `\` when the file name has
    " one); certutil: the hash alone on the second line, in byte pairs on older versions of Windows
    let l:line = substitute(substitute(l:line, '\r$', '', ''), '^\\', '', '')
    let l:hash = a:s.hash_cmd[0] ==# 'certutil'
          \ ? matchstr(substitute(l:line, ' ', '', 'g'), '^\x\{64}$')
          \ : matchstr(l:line, '^\x\{64}\ze\s')
    if !empty(l:hash)
      break
    endif
  endfor
  if tolower(l:hash) !=# a:s.hash
    throw 'zig-analyzer: ' . a:s.archive . ': the SHA-256 does not match SHA256SUMS'
  endif
  call s:exec(a:s, [s:tar, s:windows ? '-xf' : '-xzf', a:s.tmp . '/' . a:s.archive, '-C', a:s.tmp],
        \ function('s:extracted'), 'cannot unpack ' . a:s.archive)
endfunction

function! s:extracted(s, ...) abort
  let l:exe = printf('%s/%s/%s', a:s.tmp, a:s.release, s:exe_name)
  if !executable(l:exe)
    throw printf('zig-analyzer: %s has no %s/%s', a:s.archive, a:s.release, s:exe_name)
  endif
  call s:exec(a:s, [l:exe, '--version'], function('s:place'), 'the downloaded server does not run')
endfunction

function! s:place(s, ...) abort
  let l:dest = a:s.dir . '/' . a:s.release
  call delete(l:dest, 'rf')
  if rename(a:s.tmp . '/' . a:s.release, l:dest) != 0
    throw 'zig-analyzer: cannot move the release to ' . l:dest
  endif
  call delete(a:s.tmp, 'rf')
  let a:s.tmp = ''
  call s:select(a:s)
endfunction

function! s:select(s) abort
  if !empty(a:s.tmp)
    call delete(a:s.tmp, 'rf')
    let a:s.tmp = ''
  endif
  let l:current = a:s.dir . '/current'
  call writefile([a:s.release], l:current . '.tmp')
  if rename(l:current . '.tmp', l:current) != 0
    throw 'zig-analyzer: cannot write ' . l:current
  endif
  " Installed: what fails from here on is no failure of the install
  let a:s.finished = 1
  let s:busy = 0
  let l:exe = printf('%s/%s/%s', a:s.dir, a:s.release, s:exe_name)
  call s:message(printf('%s (%s) installed in %s', a:s.tag, a:s.optimize, a:s.dir . '/' . a:s.release))
  try
    call zig_analyzer#installed()
  catch
    call s:error('cannot start the installed server: ' . v:exception)
  endtry
  " The other releases (on Windows, one that a server still runs stays until the next install)
  for l:entry in readdir(a:s.dir)
    if l:entry =~# '^zig-analyzer-' && l:entry !=# a:s.release
      call delete(a:s.dir . '/' . l:entry, 'rf')
    endif
  endfor
  if a:s.on_done isnot v:null
    call call(a:s.on_done, ['', l:exe])
  endif
endfunction

" Runs `F(s, ...)`, and ends the install with what it throws
function! s:step(s, F, ...) abort
  try
    call call(a:F, [a:s] + a:000)
  catch
    if get(a:s, 'finished', 0)
      call s:error(v:exception)
    else
      call s:fail(a:s, substitute(v:exception, '^zig-analyzer: ', '', ''))
    endif
  endtry
endfunction

function! s:fail(s, why) abort
  if !empty(a:s.tmp)
    call delete(a:s.tmp, 'rf')
    let a:s.tmp = ''
  endif
  let s:busy = 0
  call s:error('install failed: ' . a:why)
  if a:s.on_done isnot v:null
    call call(a:s.on_done, [a:why, ''])
  endif
endfunction

function! s:reject(s, why) abort
  call s:error(a:why)
  if a:s.on_done isnot v:null
    call call(a:s.on_done, [a:why, ''])
  endif
endfunction

function! s:fetch(s, url, out, Next) abort
  call s:exec(a:s, ['curl', '--silent', '--show-error', '--fail', '--location', '--retry', '3',
        \ '--output', a:out, a:url], a:Next, 'cannot download ' . a:url)
endfunction

" Runs `cmd`; once it has exited and its output is read, continues with `Next(s, stdout lines)`
" when it succeeded, else ends the install with `failure` and its error output
function! s:exec(s, cmd, Next, failure) abort
  let l:job = {'out': [], 'err': [], 'pending': 2, 'status': -1, 'done': 0}
  function! l:job.finish() dict abort closure
    let self.pending -= 1
    if self.pending > 0 || self.done
      return
    endif
    let self.done = 1
    if self.status == 0
      call s:step(a:s, a:Next, self.out)
    else
      let l:detail = trim(join(self.err, ' '))
      call s:fail(a:s, a:failure . (empty(l:detail) ? '' : ': ' . l:detail))
    endif
  endfunction
  function! l:job.exited(status) dict abort
    let self.status = a:status
    call self.finish()
  endfunction
  let l:handle = job_start(a:cmd, {
        \ 'in_io': 'null',
        \ 'out_cb': {_, line -> add(l:job.out, line)},
        \ 'err_cb': {_, line -> add(l:job.err, line)},
        \ 'close_cb': {_ -> l:job.finish()},
        \ 'exit_cb': {_, status -> l:job.exited(status)},
        \ })
  if job_status(l:handle) ==# 'fail'
    let l:job.done = 1
    call timer_start(0, {_ -> s:fail(a:s, a:failure . ': cannot start ' . a:cmd[0])})
  endif
endfunction

function! s:message(text) abort
  echomsg 'zig-analyzer: ' . a:text
endfunction

function! s:warn(text) abort
  echohl WarningMsg
  echomsg 'zig-analyzer: ' . a:text
  echohl None
endfunction

function! s:error(text) abort
  echohl ErrorMsg
  echomsg 'zig-analyzer: ' . a:text
  echohl None
endfunction
