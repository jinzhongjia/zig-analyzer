-- Smoke test against a real server:
--   ZIG_ANALYZER=/path/to/zig-analyzer nvim --headless --clean -u NONE -l test/smoke.lua
-- Run with a temporary XDG_STATE_HOME to keep the LSP log out of the user's state directory.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime plugin/zig-analyzer.lua')
vim.cmd('filetype on')

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.mkdir(dir .. '/.git', 'p')
local file = dir .. '/main.zig'
vim.fn.writefile({
  'const std = @import("std");',
  '',
  'pub fn add(a: u32, b: u32) u32 {',
  '    return a + b;',
  '}',
  '',
  'pub fn main() void {',
  '    const x = add(1, 2);',
  '    std.debug.print("{}\\n", .{x});',
  '}',
}, file)

local failures = 0
local function check(cond, what)
  if cond then
    print('ok   ' .. what)
  else
    failures = failures + 1
    print('FAIL ' .. what)
  end
end

require('zig-analyzer').setup({
  cmd = { os.getenv('ZIG_ANALYZER') or 'zig-analyzer' },
  settings = { inlay_hints = { parameters = false } },
})
vim.cmd.edit(file)
check(vim.bo.filetype == 'zig', 'filetype is zig')

local client
vim.wait(20000, function()
  client = vim.lsp.get_clients({ name = 'zig_analyzer', bufnr = 0 })[1]
  return client ~= nil and client.initialized
end, 50)
check(client ~= nil, 'client attached')
if not client then os.exit(1) end
check(client.root_dir == dir, 'root directory is the .git directory')

local function request(method, params)
  local r = client:request_sync(method, params, 30000, 0)
  return r and r.result, r and r.err
end

request('zig-analyzer/waitIdle', nil)
local hover = request('textDocument/hover', { textDocument = { uri = vim.uri_from_fname(file) }, position = { line = 7, character = 15 } })
check(hover and hover.contents.value:find('fn add%(a: u32, b: u32%) u32') ~= nil, 'hover')

local hints = request('textDocument/inlayHint', {
  textDocument = { uri = vim.uri_from_fname(file) },
  range = { start = { line = 0, character = 0 }, ['end'] = { line = 10, character = 0 } },
}) or {}
local labels = {}
for _, h in ipairs(hints) do
  local l = type(h.label) == 'string' and h.label or table.concat(vim.tbl_map(function(p) return p.value end, h.label))
  table.insert(labels, l)
end
local joined = table.concat(labels, ' ')
check(joined:find('u32') ~= nil, 'type hint: ' .. joined)
check(joined:find('a:') == nil, 'settings reach the server (no parameter hints)')

vim.cmd('ZigAnalyzer syntaxTree')
vim.wait(10000, function() return vim.api.nvim_buf_get_name(0):find('syntax%-tree') ~= nil end, 50)
check(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match('^source_file@') ~= nil, ':ZigAnalyzer syntaxTree')
vim.cmd.close()

vim.cmd('ZigAnalyzer status')
vim.wait(10000, function() return vim.api.nvim_buf_get_name(0):find('status%.json') ~= nil end, 50)
check(vim.bo.filetype == 'json' and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find('"revision"') ~= nil, ':ZigAnalyzer status')
vim.cmd.close()

local old = client.id
vim.cmd('ZigAnalyzer restart')
local restarted
vim.wait(20000, function()
  restarted = vim.lsp.get_clients({ name = 'zig_analyzer', bufnr = 0 })[1]
  return restarted ~= nil and restarted.id ~= old and restarted.initialized
end, 50)
check(restarted ~= nil and restarted.id ~= old, ':ZigAnalyzer restart')

vim.cmd('checkhealth zig-analyzer')
local health = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check(health:find('server: ') ~= nil and health:find('zig_analyzer is enabled') ~= nil, ':checkhealth zig-analyzer')

for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
vim.fn.delete(dir, 'rf')
os.exit(failures == 0 and 0 or 1)
