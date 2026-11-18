-- The metadata file of the server releases (see docs/features/update-check.md): the plugin reads
-- it to learn whether a newer release exists. It never installs one; `:ZigAnalyzer install` is
-- the user's choice.
local M = {}

--- Where the release metadata is served
M.url = 'https://releases.zig-analyzer.dev/metadata.json'

--- Whether the automatic check runs; `setup({ check_updates = false })` turns it off
M.enabled = true

--- The tags that were reported in this session
M.prompted = {}

--- Whether a check is in flight
M.checking = false

--- Whether the automatic check was scheduled
M.scheduled = false

--- `setup()` without a `check_updates` key leaves the check on
---@param opts? table
function M.setup(opts)
  M.enabled = not opts or opts.check_updates ~= false
end

--- The version of the running client, or of the installed release when the client has none
---@param client? vim.lsp.Client
---@return string?
local function current_version(client)
  local version = client and client.server_info and client.server_info.version
  if type(version) == 'string' and version ~= '' then return version end
  local _, release = require('zig-analyzer.install').installed()
  return release and release:match('^zig%-analyzer%-(v%d+%.%d+%.%d+[%w.%-]*)%-')
end

--- The latest stable tag in metadata.json, or nil when it is not one
---@param body string
---@return string?
local function parse(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= 'table' or data.schema ~= 1 or type(data.latest) ~= 'string' then return nil end
  if not data.latest:match('^v%d+%.%d+%.%d+[%w.%-]*$') then return nil end
  return data.latest
end

local function parse_version(v)
  v = vim.trim(v)
  if v:sub(1, 1) == 'v' then v = v:sub(2) end
  local plus = v:find('+', 1, true)
  if plus then v = v:sub(1, plus - 1) end
  local pre = {}
  local dash = v:find('-', 1, true)
  if dash then
    pre = vim.split(v:sub(dash + 1), '.', { plain = true })
    v = v:sub(1, dash - 1)
  end
  local major, minor, patch = v:match('^(%d+)%.(%d+)%.(%d+)$')
  if not major then return nil end
  return { tonumber(major), tonumber(minor), tonumber(patch), pre }
end

--- Compares two versions as SemVer does (`v` optional, build metadata ignored): negative when `a`
--- is older than `b`, 0 when they are equal, positive when newer; nil when either is not a
--- version. A version with a pre-release (`0.2.0-rc.1`, `0.2.0-dev`) is older than its release.
---@param a string
---@param b string
---@return integer?
function M.compare(a, b)
  local va, vb = parse_version(a), parse_version(b)
  if not va or not vb then return nil end
  for i = 1, 3 do
    if va[i] ~= vb[i] then return va[i] < vb[i] and -1 or 1 end
  end
  local pa, pb = va[4], vb[4]
  if #pa == 0 and #pb == 0 then return 0 end
  if #pa == 0 then return 1 end
  if #pb == 0 then return -1 end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i], pb[i]
    if x == nil then return -1 end
    if y == nil then return 1 end
    local xn, yn = x:match('^%d+$') ~= nil, y:match('^%d+$') ~= nil
    if xn and yn then
      if tonumber(x) ~= tonumber(y) then return tonumber(x) < tonumber(y) and -1 or 1 end
    elseif xn ~= yn then
      return xn and -1 or 1
    elseif x ~= y then
      return x < y and -1 or 1
    end
  end
  return 0
end

--- Fetches `url` with curl (which the install already needs); `done` gets the body or nil
local function fetch(url, done)
  local ok = pcall(vim.system, {
    'curl', '--silent', '--show-error', '--fail', '--location', '--max-time', '5', url,
  }, { text = true }, function(res)
    vim.schedule(function() done(res.code == 0 and res.stdout or nil) end)
  end)
  if not ok then vim.schedule(function() done(nil) end) end
end

local function notify(message)
  vim.notify('zig-analyzer: ' .. message, vim.log.levels.WARN)
end

--- Checks the metadata file. `opts.force` checks even when disabled and reports a tag that was
--- reported before; `opts.version` and `opts.url` are for tests; `opts.notify` replaces the
--- notification. `on_done(tag, current, status)` gets the outcome, where `status` is `"newer"`,
--- `"up to date"`, `"no data"`, `"invalid"`, `"no version"`, `"disabled"`, `"checking"`, or
--- `"reported"`.
---@param opts? { force?: boolean, version?: string, url?: string, client?: vim.lsp.Client, notify?: fun(message: string), notify_no_version?: boolean }
---@param on_done? fun(tag: string?, current: string?, status: string)
function M.check(opts, on_done)
  opts = opts or {}
  local function done(tag, current, status)
    if on_done then on_done(tag, current, status) end
  end
  if not opts.force and not M.enabled then return done(nil, nil, 'disabled') end
  if M.checking then return done(nil, nil, 'checking') end
  local current = opts.version or current_version(opts.client)
  if not current then
    if opts.notify_no_version then notify('no running server or installed release to check') end
    return done(nil, nil, 'no version')
  end
  M.checking = true
  local function finish(tag, current, status)
    M.checking = false
    done(tag, current, status)
  end
  fetch(opts.url or M.url, function(body)
    if not body then return finish(nil, current, 'no data') end
    local tag = parse(body)
    if not tag then return finish(nil, current, 'invalid') end
    local order = M.compare(tag, current)
    if not order or order <= 0 then return finish(tag, current, 'up to date') end
    if not opts.force and M.prompted[tag] then return finish(tag, current, 'reported') end
    M.prompted[tag] = true
    ;(opts.notify or notify)(('%s is available (running %s); update it with :ZigAnalyzer install'):format(tag, current))
    finish(tag, current, 'newer')
  end)
end

--- Schedules the automatic check once, a few seconds after the first client starts
---@param client vim.lsp.Client
function M.schedule(client)
  if M.scheduled then return end
  M.scheduled = true
  local timer = vim.uv.new_timer()
  if not timer then return end
  timer:start(5000, 0, vim.schedule_wrap(function()
    timer:close()
    M.check({ client = client })
  end))
end

--- Schedules the check when a zig-analyzer client starts, and for the clients that already run
function M.attach()
  local group = vim.api.nvim_create_augroup('zig-analyzer-update', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == 'zig_analyzer' then M.schedule(client) end
    end,
  })
  for _, client in ipairs(vim.lsp.get_clients({ name = 'zig_analyzer' })) do M.schedule(client) end
end

return M
