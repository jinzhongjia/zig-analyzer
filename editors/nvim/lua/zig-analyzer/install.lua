-- `:ZigAnalyzer install`: downloads a release of the server from GitHub into
-- `stdpath('data')/zig-analyzer`, after verifying it. The release's SHA256SUMS must carry a
-- minisign signature by the release key below, whose trusted comment names the release
-- (`zig-analyzer <tag>`), and the archive must have the SHA-256 listed there. Needs `curl` and
-- `tar` (both ship with Windows 10 and later).

local minisign = require('zig-analyzer.minisign')

local M = {}

local name = 'zig_analyzer'

--- Where the releases are downloaded from
M.releases = 'https://github.com/jinzhongjia/zig-analyzer/releases'

--- The release signing key (`minisign.pub` at the root of the zig-analyzer repository)
M.public_key = 'RWRbma3B4tRgvIsJxiSxTvwoOWB6wvqxTEDgWVaJk0XMSeW9THbHBVj+'

M.optimize_modes = { 'ReleaseSafe', 'ReleaseFast' }

local windows = vim.fn.has('win32') == 1
local exe_name = windows and 'zig-analyzer.exe' or 'zig-analyzer'
-- The tar of Windows (bsdtar) extracts zip archives; another one earlier in PATH, such as the GNU
-- tar of Git for Windows, may not
local tar = windows and vim.fs.joinpath(vim.env.SystemRoot or 'C:/Windows', 'System32', 'tar.exe') or 'tar'

--- The directory installs go to
function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'zig-analyzer')
end

local function read(path, mode)
  local f = io.open(path, mode or 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function write(path, s)
  local f, err = io.open(path, 'wb')
  if not f then error(err, 0) end
  f:write(s)
  f:close()
end

--- The installed server executable and its release directory name, if there is one
---@return string? exe
---@return string? release
function M.installed()
  local release = vim.trim(read(vim.fs.joinpath(M.dir(), 'current')) or '')
  -- `zig-analyzer-<tag>-<arch>-<os>-<optimize>`; the arch may be `x86_64`
  if not release:match('^zig%-analyzer%-v[%w._%-]+$') then return nil end
  local exe = vim.fs.joinpath(M.dir(), release, exe_name)
  if vim.fn.executable(exe) == 0 then return nil end
  return exe, release
end

--- The server the default configuration starts: the installed one, else `zig-analyzer` from PATH
---@return string? exe
---@return string source `installed`, `PATH`, or `missing`
function M.command()
  local exe = M.installed()
  if exe then return exe, 'installed' end
  if vim.fn.executable('zig-analyzer') == 1 then return 'zig-analyzer', 'PATH' end
  return nil, 'missing'
end

--- The `cmd` of the default configuration: starts `M.command()` when the client starts
---@param dispatchers vim.lsp.rpc.Dispatchers
---@param config vim.lsp.ClientConfig
function M.cmd(dispatchers, config)
  local exe = M.command()
  if not exe then
    error('zig-analyzer is not installed: run `:ZigAnalyzer install`, or set `cmd` in setup()', 0)
  end
  return vim.lsp.rpc.start({ exe }, dispatchers, {
    cwd = config.cmd_cwd,
    env = config.cmd_env,
    detached = config.detached,
  })
end

--- `<arch>-<os>` of the release archive for this system, if there is one
---@return string?
function M.target()
  local uname = vim.uv.os_uname()
  local arch = ({ x86_64 = 'x86_64', amd64 = 'x86_64', AMD64 = 'x86_64', arm64 = 'aarch64', aarch64 = 'aarch64', ARM64 = 'aarch64' })[uname.machine]
  local os = ({ Linux = 'linux', Darwin = 'macos', Windows_NT = 'windows' })[uname.sysname]
  if not arch or not os then return nil end
  return arch .. '-' .. os
end

local function notify(msg, level)
  vim.notify('zig-analyzer: ' .. msg, level or vim.log.levels.INFO)
end

-- The steps run in a coroutine, resumed by the callbacks of the downloads and processes; an error
-- raised by a step ends the install and is reported
local function await(start)
  local co = coroutine.running()
  start(function(...)
    local args = vim.F.pack_len(...)
    vim.schedule(function()
      local ok, err = coroutine.resume(co, vim.F.unpack_len(args))
      if not ok then M._fail(co, err) end
    end)
  end)
  return coroutine.yield()
end

local function fetch(url, outpath)
  local err, res = await(function(done)
    vim.net.request(url, { outpath = outpath }, done)
  end)
  if err then error(('cannot download %s: %s'):format(url, vim.trim(err)), 0) end
  return res and res.body
end

local function run(cmd)
  local res = await(function(done)
    local ok, err = pcall(vim.system, cmd, { text = true }, done)
    if not ok then done({ code = -1, stdout = '', stderr = err }) end
  end)
  if res.code ~= 0 then
    error(('`%s` failed: %s'):format(table.concat(cmd, ' '), vim.trim(res.stderr or '')), 0)
  end
  return res.stdout
end

local state = {} ---@type table<thread, { tmp: string? }>

function M._fail(co, err)
  local s = state[co]
  state[co] = nil
  if s and s.tmp then vim.fn.delete(s.tmp, 'rf') end
  M.busy = false
  notify('install failed: ' .. tostring(err), vim.log.levels.ERROR)
  if s and s.on_done then s.on_done(tostring(err)) end
end

--- Whether the configuration's `cmd` is the default one (and so starts the installed server)
local function default_cmd()
  local config = vim.lsp.config[name]
  return config ~= nil and config.cmd == M.cmd
end

--- Starts the installed server: restarts the running clients, or starts the clients of open Zig
--- buffers that could not start before
local function restart()
  if not default_cmd() then
    notify('`cmd` is set in setup(), so the server it names stays in use', vim.log.levels.WARN)
    return
  end
  if #vim.lsp.get_clients({ name = name }) > 0 then
    vim.cmd('lsp restart ' .. name)
  elseif vim.lsp.is_enabled(name) then
    vim.lsp.enable(name)
  end
end

local function steps(opts)
  local co = coroutine.running()
  local s = state[co]
  local target = M.target()
  if not target then
    local u = vim.uv.os_uname()
    error(('no release for %s %s: build zig-analyzer from source and set `cmd` in setup()'):format(u.sysname, u.machine), 0)
  end
  local base = opts.version and (M.releases .. '/download/' .. opts.version) or (M.releases .. '/latest/download')
  notify(('looking up %s'):format(opts.version or 'the latest release'))
  local sums = fetch(base .. '/SHA256SUMS')
  local sig = fetch(base .. '/SHA256SUMS.minisig')
  local comment, err = minisign.verify(M.public_key, sig, sums)
  if not comment then error('SHA256SUMS: ' .. err, 0) end
  local tag = comment:match('^zig%-analyzer (v%d+%.%d+%.%d+[%w.%-]*)$')
  if not tag then error(('SHA256SUMS: unexpected trusted comment %q'):format(comment), 0) end
  if opts.version and tag ~= opts.version then
    error(('SHA256SUMS is signed for %s, not %s'):format(tag, opts.version), 0)
  end
  local release = ('zig-analyzer-%s-%s-%s'):format(tag, target, opts.optimize)
  local archive = release .. (windows and '.zip' or '.tar.gz')
  local hash
  for line in vim.gsplit(sums, '\n', { plain = true }) do
    local h, file = line:gsub('\r$', ''):match('^(%x+)  (.+)$')
    if file == archive then hash = h:lower() end
  end
  if not hash or #hash ~= 64 then error(('%s has no %s'):format(tag, archive), 0) end

  local dir = M.dir()
  local exe = vim.fs.joinpath(dir, release, exe_name)
  if select(2, M.installed()) ~= release or vim.fn.executable(exe) == 0 then
    vim.fn.mkdir(dir, 'p')
    s.tmp = vim.fs.joinpath(dir, ('.tmp-%d-%d'):format(vim.uv.os_getpid(), vim.uv.hrtime()))
    vim.fn.mkdir(s.tmp, 'p')
    notify('downloading ' .. archive)
    local file = vim.fs.joinpath(s.tmp, archive)
    -- From the verified release: `latest` may have moved on since SHA256SUMS was downloaded
    fetch(M.releases .. '/download/' .. tag .. '/' .. archive, file)
    if vim.fn.sha256(read(file, 'rb') or '') ~= hash then
      error(archive .. ': the SHA-256 does not match SHA256SUMS', 0)
    end
    run({ tar, windows and '-xf' or '-xzf', file, '-C', s.tmp })
    local new = vim.fs.joinpath(s.tmp, release, exe_name)
    if vim.fn.executable(new) == 0 then error(archive .. ' has no ' .. release .. '/' .. exe_name, 0) end
    run({ new, '--version' })
    vim.fn.delete(vim.fs.joinpath(dir, release), 'rf')
    local ok, rename_err = vim.uv.fs_rename(vim.fs.joinpath(s.tmp, release), vim.fs.joinpath(dir, release))
    if not ok then error(rename_err, 0) end
    vim.fn.delete(s.tmp, 'rf')
    s.tmp = nil
  end
  local current = vim.fs.joinpath(dir, 'current')
  write(current .. '.tmp', release .. '\n')
  local ok, rename_err = vim.uv.fs_rename(current .. '.tmp', current)
  if not ok then error(rename_err, 0) end
  state[co] = nil
  M.busy = false
  notify(('%s (%s) installed in %s'):format(tag, opts.optimize, vim.fs.joinpath(dir, release)))
  -- The previous releases, best effort: on Windows a running server keeps its executable open,
  -- and that release stays until the next install
  pcall(function()
    for entry in vim.fs.dir(dir) do
      if entry:match('^zig%-analyzer%-') and entry ~= release then vim.fn.delete(vim.fs.joinpath(dir, entry), 'rf') end
    end
  end)
  restart()
  if s.on_done then s.on_done(nil, exe) end
end

--- Installs a release: `opts.version` is a tag (`v0.1.1`; the latest release by default),
--- `opts.optimize` `ReleaseSafe` (default) or `ReleaseFast`. `opts.on_done(err, exe)` is called
--- when it ends.
---@param opts? { version?: string, optimize?: string, on_done?: fun(err: string?, exe: string?) }
function M.install(opts)
  opts = vim.deepcopy(opts or {})
  opts.optimize = opts.optimize or 'ReleaseSafe'
  local function reject(msg, level)
    notify(msg, level or vim.log.levels.ERROR)
    if opts.on_done then opts.on_done(msg) end
  end
  if not vim.tbl_contains(M.optimize_modes, opts.optimize) then
    return reject('unknown optimize mode ' .. opts.optimize)
  end
  if opts.version and not opts.version:match('^v%d+%.%d+%.%d+[%w.%-]*$') then
    return reject(('%q is not a release tag (such as v0.1.1)'):format(opts.version))
  end
  if M.busy then
    return reject('an install is already running', vim.log.levels.WARN)
  end
  M.busy = true
  local co = coroutine.create(steps)
  state[co] = { on_done = opts.on_done }
  local ok, err = coroutine.resume(co, opts)
  if not ok then M._fail(co, err) end
end

--- `:ZigAnalyzer install [<tag>|latest] [ReleaseSafe|ReleaseFast]`
---@param args string[]
function M.command_install(args)
  local opts = {}
  for _, arg in ipairs(args) do
    if vim.tbl_contains(M.optimize_modes, arg) then
      opts.optimize = arg
    elseif arg ~= 'latest' then
      opts.version = arg
    end
  end
  M.install(opts)
end

return M
