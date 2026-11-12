-- Smoke test against a real server, on a copy of editors/test-project:
--   ZIG_ANALYZER=/path/to/zig-analyzer nvim --headless --clean -u NONE -l test/smoke.lua
-- Run with a temporary XDG_STATE_HOME to keep the LSP log out of the user's state directory.
-- Needs Zig 0.17 in PATH (the project is loaded through `zig build`).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime plugin/zig-analyzer.lua')
vim.cmd('filetype on')

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.system({ 'cp', '-R', root .. '/../test-project/.', dir }):wait()
dir = vim.uv.fs_realpath(dir)

local failures = 0
local function check(cond, what)
  print((cond and 'ok   ' or 'FAIL ') .. what)
  if not cond then failures = failures + 1 end
end

local function path(rel) return dir .. '/' .. rel end
local function uri(rel) return vim.uri_from_fname(path(rel)) end

--- The position of `needle` in a file of the project, `delta` characters after its start
local function pos(rel, needle, delta)
  for i, line in ipairs(vim.fn.readfile(path(rel))) do
    local col = line:find(needle, 1, true)
    if col then return { line = i - 1, character = col - 1 + (delta or 0) } end
  end
  error('not found: ' .. needle)
end

require('zig-analyzer').setup({
  cmd = { os.getenv('ZIG_ANALYZER') or 'zig-analyzer' },
  settings = { inlay_hints = { exclude_single_argument = false } },
})

vim.cmd.edit(path('src/main.zig'))
local main_buf = vim.api.nvim_get_current_buf()
check(vim.bo.filetype == 'zig', 'filetype is zig')

local client
vim.wait(30000, function()
  client = vim.lsp.get_clients({ name = 'zig_analyzer', bufnr = 0 })[1]
  return client ~= nil and client.initialized
end, 50)
check(client ~= nil, 'client attached')
if not client then os.exit(1) end
check(client.root_dir == dir, 'root directory is the project')

local function request(method, params, bufnr)
  local r = client:request_sync(method, params, 60000, bufnr or main_buf)
  if r and r.err then print('     ' .. method .. ': ' .. r.err.message) end
  return r and r.result
end

-- Waits for the project to load (`zig build`) and for the analysis
request('zig-analyzer/waitIdle', nil)

local status = request('zig-analyzer/fileStatus', { textDocument = { uri = uri('src/main.zig') } })
check(status and #status.projects == 1 and status.projects[1].root == dir and #status.modules > 0,
  'the file belongs to the build.zig project')

local call = pos('src/main.zig', 'shapes.area(square)', 7)
local doc = { uri = uri('src/main.zig') }

local hover = request('textDocument/hover', { textDocument = doc, position = call })
local hover_text = hover and hover.contents.value or ''
check(hover_text:find('fn area(s: Square) u32', 1, true) and hover_text:find('The area of a square.', 1, true),
  'hover shows the signature and the doc comment')

local defs = request('textDocument/definition', { textDocument = doc, position = call }) or {}
local def = defs[1] or defs
check(def and (def.uri or def.targetUri) == uri('src/shapes.zig')
  and (def.range or def.targetSelectionRange).start.line == pos('src/shapes.zig', 'pub fn area').line,
  'definition in the other file')

local refs = request('textDocument/references',
  { textDocument = doc, position = call, context = { includeDeclaration = true } }) or {}
check(#refs == 3, 'references: declaration and two calls (' .. #refs .. ')')

local prepared = request('textDocument/prepareRename', { textDocument = doc, position = call })
check(prepared ~= nil, 'prepareRename')
local edit = request('textDocument/rename', { textDocument = doc, position = call, newName = 'surface' }) or {}
local edits, files = 0, 0
for _, e in pairs(edit.changes or {}) do
  files = files + 1
  edits = edits + #e
end
for _, c in ipairs(edit.documentChanges or {}) do
  files = files + 1
  edits = edits + #c.edits
end
check(files == 2 and edits == 3, ('rename: 3 edits in 2 files (%d in %d)'):format(edits, files))

local completion = request('textDocument/completion', { textDocument = doc, position = pos('src/main.zig', 'shapes.area(square)', 7) })
local labels = {}
for _, item in ipairs(completion and (completion.items or completion) or {}) do labels[item.label] = true end
check(labels.area and labels.Square, 'completion of the members of shapes')

local sig = request('textDocument/signatureHelp', { textDocument = doc, position = pos('src/main.zig', 'shapes.area(square)', 12) })
check(sig and sig.signatures[1] and sig.signatures[1].label:find('area(s: Square)', 1, true), 'signature help')

local hints = request('textDocument/inlayHint',
  { textDocument = doc, range = { start = { line = 0, character = 0 }, ['end'] = { line = 20, character = 0 } } }) or {}
local hint_labels = {}
for _, h in ipairs(hints) do
  table.insert(hint_labels, type(h.label) == 'string' and h.label or table.concat(vim.tbl_map(function(p) return p.value end, h.label)))
end
local joined = table.concat(hint_labels, ' ')
check(joined:find(': u32', 1, true), 'type hint (' .. joined .. ')')
-- Single-argument calls show no parameter names by default: this one comes from the settings
check(joined:find('s:', 1, true), 'parameter hint enabled by the settings')

local tokens = request('textDocument/semanticTokens/full', { textDocument = doc })
check(tokens and #tokens.data > 0 and #tokens.data % 5 == 0, 'semantic tokens')

-- A standard library file reached by going to a definition is attached to the running server: with
-- a root of its own (the git repository of Homebrew, or none for an official archive), it started
-- another server
local std_defs = request('textDocument/definition', { textDocument = doc, position = pos('src/main.zig', 'std.debug.print', 10) }) or {}
local std_def = std_defs[1] or std_defs
local std_uri = std_def and (std_def.uri or std_def.targetUri)
check(std_uri and std_uri:find('/std/', 1, true) ~= nil, 'definition in the standard library')
if std_uri then
  vim.cmd.edit(vim.uri_to_fname(std_uri))
  local std_buf = vim.api.nvim_get_current_buf()
  local attached
  vim.wait(10000, function()
    attached = vim.lsp.get_clients({ name = 'zig_analyzer', bufnr = std_buf })[1]
    return attached ~= nil
  end, 50)
  check(attached and attached.id == client.id and #vim.lsp.get_clients({ name = 'zig_analyzer' }) == 1,
    'the standard library file is attached to the running server')
  vim.api.nvim_set_current_buf(main_buf)
end

vim.cmd.edit(path('src/shapes.zig'))
local shapes_buf = vim.api.nvim_get_current_buf()
request('zig-analyzer/waitIdle', nil, shapes_buf)
local symbols = request('textDocument/documentSymbol', { textDocument = { uri = uri('src/shapes.zig') } }, shapes_buf) or {}
local names = {}
for _, s in ipairs(symbols) do names[s.name] = s end
check(names.Square and names.area and names.Square.children and names.Square.children[1].name == 'side',
  'document symbols with children')

local folds = request('textDocument/foldingRange', { textDocument = { uri = uri('src/shapes.zig') } }, shapes_buf) or {}
check(#folds > 0, 'folding ranges')

local ws = request('workspace/symbol', { query = 'Square' }) or {}
check(vim.iter(ws):any(function(s) return s.name == 'Square' and s.location.uri == uri('src/shapes.zig') end),
  'workspace symbol')

vim.cmd.edit(path('src/lint.zig'))
local lint_buf = vim.api.nvim_get_current_buf()
request('zig-analyzer/waitIdle', nil, lint_buf)
vim.wait(20000, function() return #vim.diagnostic.get(lint_buf) > 0 end, 50)
local diags = vim.diagnostic.get(lint_buf)
check(diags[1] and diags[1].message:find('unused local constant', 1, true), 'live diagnostic')

if diags[1] then
  local lsp_diag = diags[1].user_data and diags[1].user_data.lsp
  local actions = request('textDocument/codeAction', {
    textDocument = { uri = uri('src/lint.zig') },
    range = lsp_diag.range,
    context = { diagnostics = { lsp_diag }, only = { 'quickfix' } },
  }, lint_buf) or {}
  check(#actions > 0, 'quick fix for the unused constant (' .. #actions .. ')')
end

local fmt = request('textDocument/formatting',
  { textDocument = { uri = uri('src/lint.zig') }, options = { tabSize = 4, insertSpaces = true } }, lint_buf) or {}
check(#fmt > 0, 'formatting')

vim.cmd.edit(path('build.zig.zon'))
local zon_buf = vim.api.nvim_get_current_buf()
request('zig-analyzer/waitIdle', nil, zon_buf)
check(vim.bo.filetype == 'zig' or vim.bo.filetype == 'zon', 'build.zig.zon is handled')
vim.wait(10000, function() return #vim.lsp.get_clients({ name = 'zig_analyzer', bufnr = zon_buf }) > 0 end, 50)
local zon_symbols = request('textDocument/documentSymbol', { textDocument = { uri = uri('build.zig.zon') } }, zon_buf) or {}
check(vim.iter(zon_symbols):any(function(s) return s.name == 'name' or s.name == '.name' end), 'ZON outline')
local zon_hover = request('textDocument/hover', { textDocument = { uri = uri('build.zig.zon') }, position = pos('build.zig.zon', '.paths', 2) }, zon_buf)
check(zon_hover ~= nil, 'ZON hover on a manifest field')

vim.api.nvim_set_current_buf(main_buf)
vim.cmd('ZigAnalyzer syntaxTree')
vim.wait(10000, function() return vim.api.nvim_buf_get_name(0):find('syntax%-tree') ~= nil end, 50)
check(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match('^source_file@') ~= nil, ':ZigAnalyzer syntaxTree')
vim.cmd.close()

vim.cmd('ZigAnalyzer moduleGraph')
vim.wait(10000, function() return vim.api.nvim_buf_get_name(0):find('module%-graph') ~= nil end, 50)
check(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find(path('src/main.zig'), 1, true) ~= nil,
  ':ZigAnalyzer moduleGraph lists the project root module')
vim.cmd.close()

vim.cmd('ZigAnalyzer status')
vim.wait(10000, function() return vim.api.nvim_buf_get_name(0):find('status%.json') ~= nil end, 50)
check(vim.bo.filetype == 'json' and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find('"revision"') ~= nil,
  ':ZigAnalyzer status')
vim.cmd.close()

vim.cmd('ZigAnalyzer reloadWorkspace')
request('zig-analyzer/waitIdle', nil)
status = request('zig-analyzer/fileStatus', { textDocument = { uri = uri('src/main.zig') } })
check(status and #status.projects == 1, ':ZigAnalyzer reloadWorkspace reloads the project')

local old = client.id
vim.cmd('ZigAnalyzer restart')
local restarted
vim.wait(30000, function()
  restarted = vim.lsp.get_clients({ name = 'zig_analyzer', bufnr = main_buf })[1]
  return restarted ~= nil and restarted.id ~= old and restarted.initialized
end, 50)
check(restarted ~= nil and restarted.id ~= old, ':ZigAnalyzer restart')

vim.cmd('checkhealth zig-analyzer')
local health = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check(health:find('server: ') ~= nil and health:find('zig_analyzer is enabled') ~= nil, ':checkhealth zig-analyzer')

for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
vim.fn.delete(dir, 'rf')
print(failures == 0 and 'all checks passed' or (failures .. ' checks failed'))
os.exit(failures == 0 and 0 or 1)
