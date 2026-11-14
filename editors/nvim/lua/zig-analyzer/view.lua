-- Renders the results of the server's inspection requests as highlighted text in a scratch buffer.
-- `<CR>` follows the line under the cursor (a file, a module, a source range); in the syntax tree,
-- the range of the node under the cursor is highlighted in the source buffer.
local M = {}

local ns = vim.api.nvim_create_namespace('zig-analyzer.view')
local range_ns = vim.api.nvim_create_namespace('zig-analyzer.view.range')

--- The line targets and the source buffer of each view buffer
---@type table<integer, { targets: table<integer, table>, source?: integer }>
local state = {}

--- Lines with highlights and the target of each line
---@class zig_analyzer.View
---@field lines string[]
---@field hls { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] line, start col, end col, group
---@field targets table<integer, table> by line (1-based)
local View = {}
View.__index = View

local function new() return setmetatable({ lines = {}, hls = {}, targets = {} }, View) end

--- Appends a line made of `chunks` (strings, or `{ text, group }`)
function View:add(chunks, target)
  local text = ''
  for _, c in ipairs(chunks) do
    if type(c) == 'string' then
      text = text .. c
    else
      if c[2] then table.insert(self.hls, { #self.lines, #text, #text + #c[1], c[2] }) end
      text = text .. c[1]
    end
  end
  table.insert(self.lines, text)
  self.targets[#self.lines] = target
end

local function path(p) return vim.fn.fnamemodify(p, ':~:.') end

local function bytes(n)
  local units = { 'B', 'KiB', 'MiB', 'GiB', 'TiB' }
  local i = 1
  while n >= 1024 and i < #units do
    n = n / 1024
    i = i + 1
  end
  return i == 1 and ('%d B'):format(n) or ('%.1f %s'):format(n, units[i])
end

local function nonempty(v) return v ~= nil and v ~= vim.NIL and v ~= '' end

--- `rows` (lists of cells) as columns, numbers aligned to the right; the first row is the header
local function table_lines(v, rows, indent, groups)
  local widths = {}
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(cell)) end
  end
  for r, row in ipairs(rows) do
    local chunks = { indent }
    for i, cell in ipairs(row) do
      local pad = (' '):rep(widths[i] - vim.fn.strdisplaywidth(cell))
      if i > 1 then table.insert(chunks, '  ' .. pad) end
      table.insert(chunks, { cell, r == 1 and 'Title' or (groups and groups[i]) })
      if i == 1 and #row > 1 then table.insert(chunks, pad) end
    end
    v:add(chunks)
  end
end

--- Aligned `label value` lines. A value is a string, or a list of `{ chunks, target }` shown on
--- one line each.
local function fields(v, items)
  local width = 0
  for _, it in ipairs(items) do width = math.max(width, #it[1]) end
  for _, it in ipairs(items) do
    local values = type(it[2]) == 'string' and { { { it[2] } } } or it[2]
    if #values == 0 then values = { { { { 'none', 'Comment' } } } } end
    for i, value in ipairs(values) do
      local label = i == 1 and it[1] or ''
      v:add(vim.list_extend({ { label, 'Label' }, (' '):rep(width - #label + 2) }, value[1]), value[2])
    end
  end
end

local renderers = {}

function renderers.syntaxTree(result)
  local v = new()
  for _, line in ipairs(vim.split(result, '\n', { trimempty = true })) do
    local indent, kind, s, e, rest = line:match('^(%s*)([%w_]+)@(%d+)%.%.(%d+)(.*)$')
    local err_at, message = line:match('^error@(%d+): (.*)$')
    if err_at then
      v:add({ { 'error', 'DiagnosticError' }, { '@' .. err_at, 'Comment' }, ': ', { message, 'DiagnosticError' } },
        { range = { tonumber(err_at), tonumber(err_at) } })
    elseif kind then
      local token = rest ~= ''
      local group = kind == 'error_node' and 'DiagnosticError' or token and 'Identifier' or 'Type'
      v:add({ indent, { kind, group }, { '@' .. s .. '..' .. e, 'Comment' }, { rest, 'String' } },
        { range = { tonumber(s), tonumber(e) } })
    else
      -- A token without a range (servers before token ranges)
      local i, k, text = line:match('^(%s*)([%w_]+)( .*)$')
      v:add(i and { i, { k, 'Identifier' }, { text, 'String' } } or { line })
    end
  end
  return v
end

function renderers.moduleGraph(result)
  local v = new()
  local std = 4294967295
  local header_lines = {}
  v:add({ { 'std', 'Title' }, '  ', nonempty(result.std_root) and { path(result.std_root), 'Directory' } or { 'unknown', 'Comment' } },
    nonempty(result.std_root) and { file = result.std_root } or nil)
  local function name(i)
    local m = result.modules[i + 1]
    if not m then return 'unknown' end
    return nonempty(m.root) and path(m.root) or '(generated, path not known yet)'
  end
  for i, m in ipairs(result.modules) do
    v:add({ '' })
    header_lines[i - 1] = #v.lines + 1
    v:add({ { ('[%d]'):format(i - 1), 'Number' }, ' ', { name(i - 1), nonempty(m.root) and 'Directory' or 'Comment' },
      '  ', { ('%d file%s'):format(m.files, m.files == 1 and '' or 's'), 'Comment' } },
      nonempty(m.root) and { file = m.root } or nil)
    if nonempty(m.builtin) then
      v:add({ '    ', { 'builtin', 'Label' }, ' ', { path(m.builtin), 'Directory' } }, { file = m.builtin })
    end
    local imports = vim.deepcopy(m.imports)
    table.sort(imports, function(a, b) return a.name < b.name end)
    for _, imp in ipairs(imports) do
      if imp.module == std then
        v:add({ '    ', { 'import', 'Label' }, ' ', { imp.name, 'Identifier' }, { ' → ', 'Comment' }, { 'std', 'Title' } },
          nonempty(result.std_root) and { file = result.std_root } or nil)
      else
        v:add({ '    ', { 'import', 'Label' }, ' ', { imp.name, 'Identifier' }, { ' → ', 'Comment' },
          { ('[%d]'):format(imp.module), 'Number' }, ' ', { name(imp.module) } }, { module = imp.module })
      end
    end
  end
  -- Imports refer to modules by index: resolve them to the header lines
  for l, t in pairs(v.targets) do
    if t.module then v.targets[l] = header_lines[t.module] and { line = header_lines[t.module] } or nil end
  end
  return v
end

function renderers.fileStatus(result)
  local v = new()
  local modules, projects, roots = {}, {}, {}
  for _, m in ipairs(result.modules) do
    table.insert(modules, m == '' and { { { '(generated, path not known yet)', 'Comment' } } }
      or { { { m == 'std' and 'std' or path(m), 'Directory' } }, m ~= 'std' and { file = m } or nil })
  end
  for _, p in ipairs(result.projects) do
    local b = p.last_build
    local build = nonempty(b) and ('last build %s: %d files, %d diagnostics'):format(os.date('%Y-%m-%d %H:%M:%S', math.floor(b.at_ms / 1000)), b.files, b.diagnostics)
      or 'no build yet'
    table.insert(projects, { { { path(p.root), 'Directory' }, '  ', { build, 'Comment' } } })
  end
  for _, r in ipairs(result.single_file_roots) do
    table.insert(roots, { { { path(r), 'Directory' } }, { file = r } })
  end
  fields(v, {
    { 'File', { { { { path(result.path), 'Directory' } }, { file = result.path } } } },
    { 'Origin', result.origin },
    { 'Context', result.context },
    { 'Open', result.open and 'yes' or 'no' },
    { 'Modules', modules },
    { 'Projects', projects },
    { 'Single-file roots', roots },
  })
  return v
end

function renderers.status(result)
  local v = new()
  local causes = result.incomplete_causes or {}
  fields(v, {
    { 'Revision', tostring(result.revision) },
    { 'Files', tostring(result.files) },
    { 'Writes', tostring(result.writes) },
    { 'Deep verifications', tostring(result.deep_verifications) },
    { 'Max RSS', result.max_rss_kb > 0 and bytes(result.max_rss_kb * 1024) or 'unknown' },
    { 'Heap', result.heap_bytes > 0 and bytes(result.heap_bytes) or 'not counted' },
    { 'InternPool', ('%d items, %s'):format(result.intern_pool_items, bytes(result.intern_pool_bytes)) },
    { 'Incomplete', ('%d by cycles, %d by stack depth'):format(causes.cycle or 0, causes.stack or 0) },
  })

  local a = result.allocator
  if nonempty(a) then
    v:add({ '' })
    v:add({ { 'Allocator', 'Title' } })
    fields(v, {
      { '  Small', ('%s (peak %s)'):format(bytes(a.small), bytes(a.peak_small)) },
      { '  Resident', bytes(a.resident) },
      { '  Live slots', bytes(a.live_slots) },
      { '  Retained', bytes(a.retained) },
      { '  Returned', bytes(a.returned) },
      { '  Large', bytes(a.large) },
      { '  Segments', ('%d (decommits %d, recommits %d)'):format(a.segments, a.decommits, a.recommits) },
      { '  Occupancy', table.concat(a.occupancy, ' ') },
    })
    v:add({ '' })
    local rows = { { 'Size', 'Pages', 'Live', 'Allocs', 'Occupancy' } }
    for _, c in ipairs(a.classes) do
      table.insert(rows, { tostring(c.size), bytes(c.pages), tostring(c.live), tostring(c.allocs), table.concat(c.occupancy, ' ') })
    end
    table_lines(v, rows, '  ')
  end

  v:add({ '' })
  v:add({ { 'Queries', 'Title' }, { ' (by total time)', 'Comment' } })
  local queries = vim.deepcopy(result.queries)
  table.sort(queries, function(x, y)
    if x.total_ms ~= y.total_ms then return x.total_ms > y.total_ms end
    return x.name < y.name
  end)
  local rows = { { 'Query', 'Runs', 'Hits', 'Cutoffs', 'Total ms', 'Self ms', 'Max ms', 'Memos', 'Keys', 'Bytes', 'Deps', 'Incomplete' } }
  for _, q in ipairs(queries) do
    table.insert(rows, {
      q.name, tostring(q.executions), tostring(q.hits), tostring(q.cutoffs),
      ('%.2f'):format(q.total_ms), ('%.2f'):format(q.self_ms), ('%.2f'):format(q.max_ms),
      tostring(q.memos), tostring(q.keys), bytes(q.bytes), tostring(q.deps), tostring(q.incomplete),
    })
  end
  table_lines(v, rows, '  ', { 'Identifier' })
  return v
end

--- The 0-based line and byte column of byte `offset` in `buf`
local function position(buf, offset)
  local lo, hi = 0, vim.api.nvim_buf_line_count(buf) - 1
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if vim.api.nvim_buf_get_offset(buf, mid) <= offset then lo = mid else hi = mid - 1 end
  end
  return lo, offset - vim.api.nvim_buf_get_offset(buf, lo)
end

local function clear_range(src)
  if vim.api.nvim_buf_is_valid(src) then vim.api.nvim_buf_clear_namespace(src, range_ns, 0, -1) end
end

--- Highlights the range of the line under the cursor in the source buffer
local function show_range(buf)
  local src = state[buf].source
  if not src or not vim.api.nvim_buf_is_valid(src) then return end
  clear_range(src)
  local t = state[buf].targets[vim.api.nvim_win_get_cursor(0)[1]]
  if not t or not t.range then return end
  local sl, sc = position(src, t.range[1])
  local el, ec = position(src, t.range[2])
  vim.api.nvim_buf_set_extmark(src, range_ns, sl, sc, { end_row = el, end_col = ec, hl_group = 'Visual', strict = false })
end

--- Follows the target of the line under the cursor
local function follow(buf)
  local t = state[buf].targets[vim.api.nvim_win_get_cursor(0)[1]]
  if not t then return end
  if t.line then
    vim.api.nvim_win_set_cursor(0, { t.line, 0 })
  elseif t.file then
    vim.cmd('wincmd p')
    vim.cmd.edit(vim.fn.fnameescape(t.file))
  elseif t.range then
    local src = state[buf].source
    if not src or not vim.api.nvim_buf_is_valid(src) then return end
    local win = vim.fn.bufwinid(src)
    if win == -1 then
      vim.cmd('wincmd p')
      vim.api.nvim_win_set_buf(0, src)
      win = vim.api.nvim_get_current_win()
    end
    local line, col = position(src, t.range[1])
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { line + 1, col })
  end
end

--- Shows the result of `kind` (`status`, `fileStatus`, `syntaxTree`, `moduleGraph`) in the view
--- named `title`, reusing its window. `source` is the buffer the result describes.
function M.show(kind, title, result, source)
  local v = renderers[kind](result)
  local name = 'zig-analyzer://' .. title
  local buf = vim.iter(vim.api.nvim_list_bufs()):find(function(b)
    return state[b] ~= nil and vim.api.nvim_buf_get_name(b) == name
  end) or -1
  local win = buf ~= -1 and vim.fn.bufwinid(buf) or -1
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    pcall(vim.api.nvim_buf_set_name, buf, name)
    vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true, desc = 'Close the view' })
    vim.keymap.set('n', '<CR>', function() follow(buf) end, { buffer = buf, desc = 'Follow the line' })
  end
  if win == -1 then
    vim.cmd('botright vsplit')
    vim.api.nvim_win_set_buf(0, buf)
    win = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(win)
  end

  if state[buf] and state[buf].source then clear_range(state[buf].source) end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, v.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'zig-analyzer'
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(v.hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  state[buf] = { targets = v.targets, source = source }

  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldmethod = 'indent'
  vim.wo[win].foldlevel = 99
  vim.bo[buf].shiftwidth = 2
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  local group = vim.api.nvim_create_augroup('zig-analyzer.view.' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      if source then clear_range(source) end
      state[buf] = nil
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  if source then
    vim.api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buf, callback = function() show_range(buf) end })
  end
end

return M
