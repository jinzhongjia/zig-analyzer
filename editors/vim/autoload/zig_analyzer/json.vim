" Indented JSON, for showing request results
function! zig_analyzer#json#pretty(value, ...) abort
  let l:indent = a:0 ? a:1 : ''
  let l:inner = l:indent . '  '
  let l:t = type(a:value)
  if l:t == v:t_dict
    if empty(a:value)
      return '{}'
    endif
    let l:items = map(sort(keys(a:value)), {_, k -> l:inner . json_encode(k) . ': ' . zig_analyzer#json#pretty(a:value[k], l:inner)})
    return "{\n" . join(l:items, ",\n") . "\n" . l:indent . '}'
  elseif l:t == v:t_list
    if empty(a:value)
      return '[]'
    endif
    let l:items = map(copy(a:value), {_, v -> l:inner . zig_analyzer#json#pretty(v, l:inner)})
    return "[\n" . join(l:items, ",\n") . "\n" . l:indent . ']'
  endif
  return json_encode(a:value)
endfunction
