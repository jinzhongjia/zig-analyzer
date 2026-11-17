-- Test of the update check against version files in a temporary directory (file:// URLs):
--   nvim --headless --clean -u NONE -l test/update.lua
-- Needs curl, as `:ZigAnalyzer install` does.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)

local update = require('zig-analyzer.update')

local failures = 0
local function check(cond, what)
  print((cond and 'ok   ' or 'FAIL ') .. what)
  if not cond then failures = failures + 1 end
end

-- Compare as SemVer does, with the `v` prefix and build metadata of the release tags
local versions = {
  { 'v0.2.0', '0.1.2', 1 },
  { '0.1.10', '0.1.9', 1 },
  { '0.1.2', '0.1.2+3.gabc1234', 0 },
  { 'v0.1.2', '0.1.2', 0 },
  { '0.1.2', '0.1.2-dev+d8b0905', 1 },
  { '0.1.2-rc.1', '0.1.2', -1 },
  { '0.1.2-alpha', '0.1.2-alpha.1', -1 },
  { '0.1.2-alpha.2', '0.1.2-alpha.10', -1 },
  { 'nightly', '0.1.2', nil },
}
for _, v in ipairs(versions) do
  check(update.compare(v[1], v[2]) == v[3], ('compare(%s, %s) is %s'):format(v[1], v[2], tostring(v[3])))
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local function write(name, text)
  local f, err = io.open(dir .. '/' .. name, 'wb')
  if not f then error(err, 0) end
  f:write(text)
  f:close()
end
write('newer.json', '{"schema":1,"tag":"v9.9.9"}\n')
write('equal.json', '{"schema":1,"tag":"v0.1.2"}\n')
write('schema.json', '{"schema":2,"tag":"v9.9.9"}\n')
write('tag.json', '{"schema":1,"tag":"nightly"}\n')
write('invalid.json', 'not json\n')

local seen = {}
local function notify(message) table.insert(seen, message) end

local function run(opts)
  local result
  update.check(opts, function(tag, current, status) result = { tag = tag, current = current, status = status } end)
  vim.wait(5000, function() return result ~= nil end, 50)
  return result
end

local function url(name) return 'file://' .. dir .. '/' .. name end

seen = {}
local r = run({ version = '0.1.2', url = url('newer.json'), force = true, notify = notify })
check(r and r.status == 'newer' and r.tag == 'v9.9.9' and #seen == 1 and seen[1]:find('v9.9.9', 1, true) ~= nil,
  'a newer release is reported')

seen = {}
r = run({ version = '0.1.2', url = url('equal.json'), force = true, notify = notify })
check(r and r.status == 'up to date' and #seen == 0, 'an equal release is not reported')

seen = {}
r = run({ version = '0.1.2', url = url('newer.json'), notify = notify })
check(r and r.status == 'reported' and #seen == 0, 'a tag is reported once')

for _, name in ipairs({ 'schema.json', 'tag.json', 'invalid.json' }) do
  seen = {}
  r = run({ version = '0.1.2', url = url(name), force = true, notify = notify })
  check(r and r.status == 'invalid' and #seen == 0, name .. ' is ignored')
end

seen = {}
r = run({ version = '0.1.2', url = url('missing.json'), force = true, notify = notify })
check(r and r.status == 'no data' and #seen == 0, 'a missing version file gives no update')

seen = {}
r = run({ version = '0.1.2', url = url('newer.json'), force = true, notify = notify })
check(r and r.status == 'newer' and #seen == 1, 'a forced check reports again')

vim.fn.delete(dir, 'rf')
print(failures == 0 and 'all checks passed' or (failures .. ' checks failed'))
os.exit(failures == 0 and 0 or 1)
