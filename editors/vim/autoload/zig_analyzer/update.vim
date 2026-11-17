" The version file of the server releases (see docs/features/update-check.md): the plugin reads
" it to learn whether a newer release exists. It never installs one; `:ZigAnalyzer install` is
" the user's choice.

if !exists('g:zig_analyzer_update_url')
  let g:zig_analyzer_update_url = 'https://zig-analyzer.nvimer.org/latest.json'
endif

let s:checking = 0
let s:scheduled = 0
let s:prompted = {}

" The parsed version: a List of major, minor, patch, and the pre-release identifiers; [] when
" `v` is not a version. Build metadata after `+` is ignored.
function! s:parse_version(v) abort
  let l:v = trim(a:v)
  if strpart(l:v, 0, 1) ==# 'v'
    let l:v = strpart(l:v, 1)
  endif
  let l:plus = stridx(l:v, '+')
  if l:plus >= 0
    let l:v = strpart(l:v, 0, l:plus)
  endif
  let l:pre = []
  let l:dash = stridx(l:v, '-')
  if l:dash >= 0
    let l:pre = split(strpart(l:v, l:dash + 1), '\.')
    let l:v = strpart(l:v, 0, l:dash)
  endif
  let l:parts = split(l:v, '\.')
  if len(l:parts) != 3
        \ || l:parts[0] !~# '^\d\+$'
        \ || l:parts[1] !~# '^\d\+$'
        \ || l:parts[2] !~# '^\d\+$'
    return []
  endif
  return [str2nr(l:parts[0]), str2nr(l:parts[1]), str2nr(l:parts[2]), l:pre]
endfunction

" Compares two versions as SemVer does (`v` optional, build metadata ignored): -1 when `a` is
" older than `b`, 0 when they are equal, 1 when newer; -2 when either is not a version. A version
" with a pre-release (`0.2.0-rc.1`, `0.2.0-dev`) is older than its release.
function! zig_analyzer#update#compare(a, b) abort
  let l:a = s:parse_version(a:a)
  let l:b = s:parse_version(a:b)
  if empty(l:a) || empty(l:b)
    return -2
  endif
  for l:i in range(3)
    if l:a[l:i] != l:b[l:i]
      return l:a[l:i] < l:b[l:i] ? -1 : 1
    endif
  endfor
  if empty(l:a[3]) && empty(l:b[3])
    return 0
  elseif empty(l:a[3])
    return 1
  elseif empty(l:b[3])
    return -1
  endif
  for l:i in range(max([len(l:a[3]), len(l:b[3])]))
    if l:i >= len(l:a[3])
      return -1
    elseif l:i >= len(l:b[3])
      return 1
    endif
    let l:x = l:a[3][l:i]
    let l:y = l:b[3][l:i]
    let l:xn = l:x =~# '^\d\+$'
    let l:yn = l:y =~# '^\d\+$'
    if l:xn && l:yn
      if str2nr(l:x) != str2nr(l:y)
        return str2nr(l:x) < str2nr(l:y) ? -1 : 1
      endif
    elseif l:xn != l:yn
      return l:xn ? -1 : 1
    elseif l:x !=# l:y
      return l:x <# l:y ? -1 : 1
    endif
  endfor
  return 0
endfunction

" The running server's version: `--version` of the command the plugin starts
function! s:version() abort
  let l:cmd = zig_analyzer#cmd()
  if empty(l:cmd)
    return ''
  endif
  try
    return trim(system(l:cmd + ['--version']))
  catch
    return ''
  endtry
endfunction

" Runs curl (which the install already needs) and calls `Callback(status, body)` in a timer
function! s:fetch(url, Callback) abort
  let l:state = {'out': [], 'done': 0}
  let l:Exit = function('s:fetch_exit', [a:Callback, l:state])
  try
    let l:job = job_start(['curl', '--silent', '--show-error', '--fail', '--location',
          \ '--max-time', '5', a:url], {
          \ 'out_cb': {ch, msg -> add(l:state.out, msg)},
          \ 'exit_cb': {job, status -> l:Exit(status)},
          \ })
    if job_status(l:job) ==# 'fail'
      call l:Exit(-1)
    endif
  catch
    call l:Exit(-1)
  endtry
endfunction

function! s:fetch_exit(Callback, state, status) abort
  if a:state.done
    return
  endif
  let a:state.done = 1
  call timer_start(0, {-> call(a:Callback, [a:status, join(a:state.out, "\n")])})
endfunction

function! s:done(opts, tag, version) abort
  if has_key(a:opts, 'on_done')
    call call(a:opts.on_done, [a:tag, a:version])
  endif
endfunction

function! s:checked(opts, version, status, body) abort
  let s:checking = 0
  if a:status != 0
    call s:done(a:opts, '', a:version)
    return
  endif
  try
    let l:data = json_decode(a:body)
  catch
    call s:done(a:opts, '', a:version)
    return
  endtry
  if type(l:data) != v:t_dict || get(l:data, 'schema', 0) != 1 || type(get(l:data, 'tag', 0)) != v:t_string
    call s:done(a:opts, '', a:version)
    return
  endif
  let l:tag = l:data.tag
  if l:tag !~# '^v\d\+\.\d\+\.\d\+[0-9A-Za-z.-]*$'
    call s:done(a:opts, '', a:version)
    return
  endif
  if zig_analyzer#update#compare(l:tag, a:version) != 1
    call s:done(a:opts, l:tag, a:version)
    return
  endif
  if !get(a:opts, 'force', 0) && has_key(s:prompted, l:tag)
    call s:done(a:opts, l:tag, a:version)
    return
  endif
  let s:prompted[l:tag] = 1
  let l:message = printf('%s is available (running %s); update it with :ZigAnalyzer install', l:tag, a:version)
  if has_key(a:opts, 'notify')
    call call(a:opts.notify, [l:message])
  else
    echohl WarningMsg
    echomsg 'zig-analyzer: ' . l:message
    echohl None
  endif
  call s:done(a:opts, l:tag, a:version)
endfunction

" Reads the version file and reports a newer release. `opts.force` checks even when the
" automatic check is off and reports a tag that was reported before; `opts.version` and
" `opts.url` are for tests; `opts.notify` replaces the message.
function! zig_analyzer#update#check(...) abort
  let l:opts = a:0 ? a:1 : {}
  if s:checking
    return
  elseif !get(l:opts, 'force', 0) && !get(g:, 'zig_analyzer_check_updates', 1)
    return
  endif
  let l:version = get(l:opts, 'version', '')
  if empty(l:version)
    let l:version = s:version()
  endif
  if empty(l:version)
    if get(l:opts, 'notify_no_version', 0)
      echohl WarningMsg
      echomsg 'zig-analyzer: no running server or installed release to check'
      echohl None
    endif
    call s:done(l:opts, '', '')
    return
  endif
  let s:checking = 1
  call s:fetch(get(l:opts, 'url', g:zig_analyzer_update_url), function('s:checked', [l:opts, l:version]))
endfunction

" Schedules the automatic check once, a few seconds after startup or after the first Zig file
function! zig_analyzer#update#schedule() abort
  if s:scheduled || !get(g:, 'zig_analyzer_check_updates', 1)
    return
  endif
  let s:scheduled = 1
  call timer_start(5000, {-> zig_analyzer#update#check()})
endfunction
