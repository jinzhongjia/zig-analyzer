" Renders the results of the server's inspection requests as highlighted text in a scratch buffer.
" `<CR>` follows the line under the cursor (a file, a module, a source range); in the syntax tree,
" the range of the node under the cursor is highlighted in the source buffer.

" The line targets and the source buffer of each view buffer, by buffer number
let s:state = {}

let s:std_module = 4294967295

function! s:new() abort
  return {'lines': [], 'hls': [], 'targets': {}}
endfunction

" Appends a line made of `chunks` (strings, or `[text, group]`) to the view `v`
function! s:add(v, chunks, ...) abort
  let l:text = ''
  for l:c in a:chunks
    if type(l:c) == v:t_string
      let l:text .= l:c
      continue
    endif
    if len(l:c) > 1 && !empty(l:c[1]) && !empty(l:c[0])
      call add(a:v.hls, [len(a:v.lines) + 1, len(l:text) + 1, len(l:c[0]), l:c[1]])
    endif
    let l:text .= l:c[0]
  endfor
  call add(a:v.lines, l:text)
  if a:0 && !empty(a:1)
    let a:v.targets[len(a:v.lines)] = a:1
  endif
endfunction

function! s:path(p) abort
  return fnamemodify(a:p, ':~:.')
endfunction

function! s:nonempty(v) abort
  return a:v isnot v:null && !(type(a:v) == v:t_string && empty(a:v))
endfunction

function! s:bytes(n) abort
  let l:units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  let l:n = a:n * 1.0
  let l:i = 0
  while l:n >= 1024 && l:i < len(l:units) - 1
    let l:n = l:n / 1024
    let l:i += 1
  endwhile
  return l:i == 0 ? printf('%d B', a:n) : printf('%.1f %s', l:n, l:units[l:i])
endfunction

" `rows` (lists of cells) as columns, all but the first aligned to the right; the first row is the
" header
function! s:table(v, rows, indent, groups) abort
  let l:widths = []
  for l:row in a:rows
    for l:i in range(len(l:row))
      if l:i >= len(l:widths)
        call add(l:widths, 0)
      endif
      let l:widths[l:i] = max([l:widths[l:i], strdisplaywidth(l:row[l:i])])
    endfor
  endfor
  for l:r in range(len(a:rows))
    let l:row = a:rows[l:r]
    let l:chunks = [a:indent]
    for l:i in range(len(l:row))
      let l:pad = repeat(' ', l:widths[l:i] - strdisplaywidth(l:row[l:i]))
      if l:i > 0
        call add(l:chunks, '  ' . l:pad)
      endif
      call add(l:chunks, [l:row[l:i], l:r == 0 ? 'Title' : get(a:groups, l:i, '')])
      if l:i == 0 && len(l:row) > 1
        call add(l:chunks, l:pad)
      endif
    endfor
    call s:add(a:v, l:chunks)
  endfor
endfunction

" Aligned `label value` lines. A value is a string, or a list of `[chunks, target]` shown on one
" line each.
function! s:fields(v, items) abort
  let l:width = max(map(copy(a:items), 'len(v:val[0])'))
  for l:it in a:items
    let l:values = type(l:it[1]) == v:t_string ? [[[l:it[1]], {}]] : l:it[1]
    if empty(l:values)
      let l:values = [[[['none', 'Comment']], {}]]
    endif
    for l:i in range(len(l:values))
      let l:label = l:i == 0 ? l:it[0] : ''
      call s:add(a:v, [[l:label, 'Label'], repeat(' ', l:width - len(l:label) + 2)] + l:values[l:i][0], l:values[l:i][1])
    endfor
  endfor
endfunction

function! s:syntaxTree(result) abort
  let l:v = s:new()
  for l:line in split(a:result, "\n")
    let l:err = matchlist(l:line, '^error@\(\d\+\): \(.*\)$')
    let l:m = matchlist(l:line, '^\(\s*\)\(\w\+\)@\(\d\+\)\.\.\(\d\+\)\(.*\)$')
    if !empty(l:err)
      call s:add(l:v, [['error', 'WarningMsg'], ['@' . l:err[1], 'Comment'], ': ', [l:err[2], 'WarningMsg']],
            \ {'range': [str2nr(l:err[1]), str2nr(l:err[1])]})
    elseif !empty(l:m)
      let l:group = l:m[2] ==# 'error_node' ? 'WarningMsg' : (empty(l:m[5]) ? 'Type' : 'Identifier')
      call s:add(l:v, [l:m[1], [l:m[2], l:group], ['@' . l:m[3] . '..' . l:m[4], 'Comment'], [l:m[5], 'String']],
            \ {'range': [str2nr(l:m[3]), str2nr(l:m[4])]})
    else
      " A token without a range (servers before token ranges)
      let l:t = matchlist(l:line, '^\(\s*\)\(\w\+\)\( .*\)$')
      call s:add(l:v, empty(l:t) ? [l:line] : [l:t[1], [l:t[2], 'Identifier'], [l:t[3], 'String']])
    endif
  endfor
  return l:v
endfunction

function! s:module_name(result, i) abort
  if a:i >= len(a:result.modules)
    return 'unknown'
  endif
  let l:root = a:result.modules[a:i].root
  return s:nonempty(l:root) ? s:path(l:root) : '(generated, path not known yet)'
endfunction

function! s:moduleGraph(result) abort
  let l:v = s:new()
  let l:std = get(a:result, 'std_root', v:null)
  let l:std_target = s:nonempty(l:std) ? {'file': l:std} : {}
  call s:add(l:v, [['std', 'Title'], '  ', s:nonempty(l:std) ? [s:path(l:std), 'Directory'] : ['unknown', 'Comment']], l:std_target)
  let l:headers = {}
  for l:i in range(len(a:result.modules))
    let l:m = a:result.modules[l:i]
    call s:add(l:v, [''])
    let l:headers[l:i] = len(l:v.lines) + 1
    call s:add(l:v, [[printf('[%d]', l:i), 'Number'], ' ', [s:module_name(a:result, l:i), s:nonempty(l:m.root) ? 'Directory' : 'Comment'],
          \ '  ', [printf('%d file%s', l:m.files, l:m.files == 1 ? '' : 's'), 'Comment']],
          \ s:nonempty(l:m.root) ? {'file': l:m.root} : {})
    if s:nonempty(get(l:m, 'builtin', v:null))
      call s:add(l:v, ['    ', ['builtin', 'Label'], ' ', [s:path(l:m.builtin), 'Directory']], {'file': l:m.builtin})
    endif
    for l:imp in sort(copy(l:m.imports), {a, b -> a.name ==# b.name ? 0 : a.name ># b.name ? 1 : -1})
      if l:imp.module == s:std_module
        call s:add(l:v, ['    ', ['import', 'Label'], ' ', [l:imp.name, 'Identifier'], [' → ', 'Comment'], ['std', 'Title']], l:std_target)
      else
        call s:add(l:v, ['    ', ['import', 'Label'], ' ', [l:imp.name, 'Identifier'], [' → ', 'Comment'],
              \ [printf('[%d]', l:imp.module), 'Number'], ' ', s:module_name(a:result, l:imp.module)], {'module': l:imp.module})
      endif
    endfor
  endfor
  " Imports refer to modules by index: resolve them to the header lines
  for [l:lnum, l:t] in items(l:v.targets)
    if has_key(l:t, 'module')
      if has_key(l:headers, l:t.module)
        let l:v.targets[l:lnum] = {'line': l:headers[l:t.module]}
      else
        call remove(l:v.targets, l:lnum)
      endif
    endif
  endfor
  return l:v
endfunction

function! s:fileStatus(result) abort
  let l:v = s:new()
  let l:modules = []
  for l:m in a:result.modules
    if empty(l:m)
      call add(l:modules, [[['(generated, path not known yet)', 'Comment']], {}])
    else
      call add(l:modules, [[[l:m ==# 'std' ? 'std' : s:path(l:m), 'Directory']], l:m ==# 'std' ? {} : {'file': l:m}])
    endif
  endfor
  let l:projects = []
  for l:p in a:result.projects
    let l:b = get(l:p, 'last_build', v:null)
    let l:build = s:nonempty(l:b)
          \ ? printf('last build %s: %d files, %d diagnostics', strftime('%Y-%m-%d %H:%M:%S', l:b.at_ms / 1000), l:b.files, l:b.diagnostics)
          \ : 'no build yet'
    call add(l:projects, [[[s:path(l:p.root), 'Directory'], '  ', [l:build, 'Comment']], {}])
  endfor
  let l:roots = map(copy(a:result.single_file_roots), {_, r -> [[[s:path(r), 'Directory']], {'file': r}]})
  call s:fields(l:v, [
        \ ['File', [[[[s:path(a:result.path), 'Directory']], {'file': a:result.path}]]],
        \ ['Origin', a:result.origin],
        \ ['Context', a:result.context],
        \ ['Open', a:result.open ? 'yes' : 'no'],
        \ ['Modules', l:modules],
        \ ['Projects', l:projects],
        \ ['Single-file roots', l:roots],
        \ ])
  return l:v
endfunction

function! s:by_total(a, b) abort
  if a:a.total_ms != a:b.total_ms
    return a:a.total_ms > a:b.total_ms ? -1 : 1
  endif
  return a:a.name ==# a:b.name ? 0 : a:a.name ># a:b.name ? 1 : -1
endfunction

function! s:status(result) abort
  let l:v = s:new()
  let l:causes = get(a:result, 'incomplete_causes', {})
  call s:fields(l:v, [
        \ ['Revision', string(a:result.revision)],
        \ ['Files', string(a:result.files)],
        \ ['Writes', string(a:result.writes)],
        \ ['Deep verifications', string(a:result.deep_verifications)],
        \ ['Max RSS', a:result.max_rss_kb > 0 ? s:bytes(a:result.max_rss_kb * 1024) : 'unknown'],
        \ ['Heap', a:result.heap_bytes > 0 ? s:bytes(a:result.heap_bytes) : 'not counted'],
        \ ['InternPool', printf('%d items, %s', a:result.intern_pool_items, s:bytes(a:result.intern_pool_bytes))],
        \ ['Incomplete', printf('%d by cycles, %d by stack depth', get(l:causes, 'cycle', 0), get(l:causes, 'stack', 0))],
        \ ])

  let l:a = get(a:result, 'allocator', v:null)
  if s:nonempty(l:a)
    call s:add(l:v, [''])
    call s:add(l:v, [['Allocator', 'Title']])
    call s:fields(l:v, [
          \ ['  Small', printf('%s (peak %s)', s:bytes(l:a.small), s:bytes(l:a.peak_small))],
          \ ['  Resident', s:bytes(l:a.resident)],
          \ ['  Live slots', s:bytes(l:a.live_slots)],
          \ ['  Retained', s:bytes(l:a.retained)],
          \ ['  Returned', s:bytes(l:a.returned)],
          \ ['  Large', s:bytes(l:a.large)],
          \ ['  Segments', printf('%d (decommits %d, recommits %d)', l:a.segments, l:a.decommits, l:a.recommits)],
          \ ['  Occupancy', join(l:a.occupancy)],
          \ ])
    call s:add(l:v, [''])
    let l:rows = [['Size', 'Pages', 'Live', 'Allocs', 'Occupancy']]
    for l:c in l:a.classes
      call add(l:rows, [string(l:c.size), s:bytes(l:c.pages), string(l:c.live), string(l:c.allocs), join(l:c.occupancy)])
    endfor
    call s:table(l:v, l:rows, '  ', [])
  endif

  call s:add(l:v, [''])
  call s:add(l:v, [['Queries', 'Title'], [' (by total time)', 'Comment']])
  let l:rows = [['Query', 'Runs', 'Hits', 'Cutoffs', 'Total ms', 'Self ms', 'Max ms', 'Memos', 'Keys', 'Bytes', 'Deps', 'Incomplete']]
  for l:q in sort(copy(a:result.queries), function('s:by_total'))
    call add(l:rows, [l:q.name, string(l:q.executions), string(l:q.hits), string(l:q.cutoffs),
          \ printf('%.2f', l:q.total_ms * 1.0), printf('%.2f', l:q.self_ms * 1.0), printf('%.2f', l:q.max_ms * 1.0),
          \ string(l:q.memos), string(l:q.keys), s:bytes(l:q.bytes), string(l:q.deps), string(l:q.incomplete)])
  endfor
  call s:table(l:v, l:rows, '  ', ['Identifier'])
  return l:v
endfunction

" The 1-based line and byte column of byte `offset` in buffer `buf`
function! s:position(buf, offset) abort
  let l:st = s:state[bufnr('%')]
  let l:tick = getbufvar(a:buf, 'changedtick')
  if get(l:st, 'tick', -1) != l:tick
    " Byte offsets of the line starts
    let l:starts = [0]
    for l:line in getbufline(a:buf, 1, '$')
      call add(l:starts, l:starts[-1] + len(l:line) + 1)
    endfor
    let l:st.starts = l:starts[: -2]
    let l:st.tick = l:tick
  endif
  let l:lo = 0
  let l:hi = len(l:st.starts) - 1
  while l:lo < l:hi
    let l:mid = (l:lo + l:hi + 1) / 2
    if l:st.starts[l:mid] <= a:offset
      let l:lo = l:mid
    else
      let l:hi = l:mid - 1
    endif
  endwhile
  return [l:lo + 1, a:offset - l:st.starts[l:lo] + 1]
endfunction

function! s:clear_range(src) abort
  if has('textprop') && bufexists(a:src) && !empty(prop_type_get('zig_analyzer_range'))
    call prop_remove({'type': 'zig_analyzer_range', 'bufnr': a:src, 'all': 1})
  endif
endfunction

" A column of `buf` that `prop_add` accepts: at most just after the end of the line
function! s:clamp(buf, pos) abort
  let l:line = get(getbufline(a:buf, a:pos[0]), 0, '')
  return [a:pos[0], max([1, min([a:pos[1], len(l:line) + 1])])]
endfunction

" Highlights the range of the line under the cursor in the source buffer
function! s:show_range() abort
  let l:st = get(s:state, bufnr('%'), {})
  let l:src = get(l:st, 'source', -1)
  if !has('textprop') || !bufexists(l:src)
    return
  endif
  call s:clear_range(l:src)
  let l:t = get(l:st.targets, line('.'), {})
  if !has_key(l:t, 'range')
    return
  endif
  if empty(prop_type_get('zig_analyzer_range'))
    highlight default link ZigAnalyzerRange Visual
    call prop_type_add('zig_analyzer_range', {'highlight': 'ZigAnalyzerRange', 'priority': 100})
  endif
  let [l:sl, l:sc] = s:clamp(l:src, s:position(l:src, l:t.range[0]))
  let [l:el, l:ec] = s:clamp(l:src, s:position(l:src, l:t.range[1]))
  if [l:sl, l:sc] != [l:el, l:ec]
    call prop_add(l:sl, l:sc, {'end_lnum': l:el, 'end_col': l:ec, 'type': 'zig_analyzer_range', 'bufnr': l:src})
  endif
endfunction

" Follows the target of the line under the cursor
function! zig_analyzer#view#follow() abort
  let l:st = get(s:state, bufnr('%'), {})
  let l:t = get(get(l:st, 'targets', {}), line('.'), {})
  if has_key(l:t, 'line')
    call cursor(l:t.line, 1)
  elseif has_key(l:t, 'file')
    wincmd p
    execute 'edit ' . fnameescape(l:t.file)
  elseif has_key(l:t, 'range') && bufexists(get(l:st, 'source', -1))
    let l:pos = s:position(l:st.source, l:t.range[0])
    let l:win = bufwinid(l:st.source)
    if l:win == -1
      wincmd p
      execute 'buffer ' . l:st.source
    else
      call win_gotoid(l:win)
    endif
    call cursor(l:pos[0], l:pos[1])
  endif
endfunction

function! s:wiped(buf) abort
  let l:st = remove(s:state, a:buf)
  if has_key(l:st, 'source')
    call s:clear_range(l:st.source)
  endif
endfunction

" Shows the result of `kind` (`status`, `fileStatus`, `syntaxTree`, `moduleGraph`) in the view
" named `title`, reusing its window. `source` is the buffer the result describes, or -1.
function! zig_analyzer#view#show(kind, title, result, source) abort
  let l:v = function('s:' . a:kind)(a:result)
  let l:name = 'zig-analyzer://' . a:title
  let l:buf = -1
  for l:b in keys(s:state)
    if bufname(str2nr(l:b)) ==# l:name
      let l:buf = str2nr(l:b)
    endif
  endfor
  if l:buf == -1
    botright vnew
    let l:buf = bufnr('%')
    setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
    silent! execute 'file ' . fnameescape(l:name)
    nnoremap <buffer> <silent> <nowait> q :close<CR>
    nnoremap <buffer> <silent> <CR> :call zig_analyzer#view#follow()<CR>
  elseif bufwinid(l:buf) == -1
    botright vsplit
    execute 'buffer ' . l:buf
  else
    call win_gotoid(bufwinid(l:buf))
  endif

  if has_key(s:state, l:buf) && has_key(s:state[l:buf], 'source')
    call s:clear_range(s:state[l:buf].source)
  endif
  let s:state[l:buf] = {'targets': l:v.targets}
  if a:source != -1
    let s:state[l:buf].source = a:source
  endif

  setlocal modifiable
  silent %delete _
  call setline(1, l:v.lines)
  setlocal nomodifiable filetype=zig-analyzer
  setlocal nowrap nonumber norelativenumber foldmethod=indent foldlevel=99 shiftwidth=2
  if exists('&signcolumn')
    setlocal signcolumn=no
  endif
  if has('textprop')
    for [l:lnum, l:col, l:len, l:group] in l:v.hls
      let l:type = 'zig_analyzer_' . l:group
      if empty(prop_type_get(l:type))
        " A group of its own: `l:group` is not defined before `:syntax on`
        execute 'highlight default link ZigAnalyzer' . l:group . ' ' . l:group
        call prop_type_add(l:type, {'highlight': 'ZigAnalyzer' . l:group})
      endif
      call prop_add(l:lnum, l:col, {'length': l:len, 'type': l:type})
    endfor
  endif
  call cursor(1, 1)

  augroup zig_analyzer_view
    autocmd! * <buffer>
    autocmd BufWipeout <buffer> call s:wiped(str2nr(expand('<abuf>')))
    if a:source != -1
      autocmd CursorMoved <buffer> call s:show_range()
    endif
  augroup END
endfunction
