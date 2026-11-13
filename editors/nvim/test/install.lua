-- Test of `:ZigAnalyzer install` against fake releases in a temporary directory (file:// URLs),
-- signed with a temporary key by test/release.mjs:
--   ZIG_ANALYZER=/path/to/zig-analyzer nvim --headless --clean -u NONE -l test/install.lua
-- Run with temporary XDG_DATA_HOME and XDG_STATE_HOME: installs go to stdpath('data'). Needs Node
-- (for the signatures), curl, tar, and Zig 0.17 in PATH.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime plugin/zig-analyzer.lua')
vim.cmd('filetype on')
local failures = 0
local function check(cond, what)
  print((cond and 'ok   ' or 'FAIL ') .. what)
  if not cond then failures = failures + 1 end
end
local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end
local function sh(cmd)
  local r = vim.system(cmd, { text = true }):wait()
  if r.code ~= 0 then error(table.concat(cmd, ' ') .. ': ' .. (r.stderr or '')) end
  return r.stdout
end

local minisign = require('zig-analyzer.minisign')
local install = require('zig-analyzer.install')

-- Known answers: SHA-512 and BLAKE2b-512 (as Node's crypto computes them) and RFC 8032 tests 1-3
local function hex(s) return (s:gsub('.', function(c) return ('%02x'):format(c:byte()) end)) end
local function unhex(h) return (h:gsub('..', function(x) return string.char(tonumber(x, 16)) end)) end
local hashes = {
  { '', 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e',
    '786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce' },
  { 'abc', 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
    'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923' },
  { ('a'):rep(1000), '67ba5535a46e3f86dbfbed8cbbaf0125c76ed549ff8b0b9e03e0c88cf90fa634fa7b12b47d77b694de488ace8d9a65967dc96df599727d3292a8d9d447709c97',
    'd6a69459fe93fc6b9537ed4336e5099e0dcca3e97290a412500ed7a0daffb03d80cf3650a20e0591f748e10c3c534945ee83d5f2c9722f1a68d98b8c01af23fd' },
}
for _, h in ipairs(hashes) do
  check(hex(minisign.sha512(h[1])) == h[2] and hex(minisign.blake2b(h[1])) == h[3], ('SHA-512 and BLAKE2b-512 of %d bytes'):format(#h[1]))
end
local rfc8032 = {
  { 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', '',
    'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b' },
  { '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c', '72',
    '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00' },
  { 'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025', 'af82',
    '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a' },
}
for i, v in ipairs(rfc8032) do
  local pk, msg, sig = unhex(v[1]), unhex(v[2]), unhex(v[3])
  local bad = sig:sub(1, 40) .. string.char((sig:byte(41) + 1) % 256) .. sig:sub(42)
  check(minisign.ed25519_verify(sig, msg, pk) and not minisign.ed25519_verify(bad, msg, pk)
    and not minisign.ed25519_verify(sig, msg .. 'x', pk), 'Ed25519 RFC 8032 test ' .. i)
end

-- Signature checks, on the files of the v0.1.1 release
local sums = read(root .. '/test/fixtures/SHA256SUMS')
local sig = read(root .. '/test/fixtures/SHA256SUMS.minisig')
check(minisign.verify(install.public_key, sig, sums) == 'zig-analyzer v0.1.1', 'release signature verifies')
check(minisign.verify(install.public_key, sig, (sums:gsub('%x', '0', 1))) == nil, 'edited SHA256SUMS is rejected')
check(minisign.verify(install.public_key, (sig:gsub('v0%.1%.1', 'v0.1.2')), sums) == nil, 'edited trusted comment is rejected')
local pub = read(root .. '/../../minisign.pub')
if pub then
  check(vim.split(pub, '\n')[2] == install.public_key, 'the key is that of minisign.pub')
else
  print('skip the key is that of minisign.pub (not in the zig-analyzer repository)')
end

-- Fake releases
local server = vim.fn.exepath(os.getenv('ZIG_ANALYZER') or 'zig-analyzer')
assert(server ~= '', 'set ZIG_ANALYZER to a zig-analyzer executable')
local tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
tmp = vim.uv.fs_realpath(tmp)
local key = tmp .. '/key.pem'
local function signer(...) return sh({ 'node', root .. '/test/release.mjs', ... }) end
install.public_key = signer('key', key)
local other = tmp .. '/other.pem'
signer('key', other)
local target = assert(install.target())
local releases = tmp .. '/releases'
install.releases = 'file://' .. releases

--- Writes the release `tag` to releases/download/<tag> and, with `latest`, to releases/latest/download
local function release(tag, opts)
  opts = opts or {}
  local dir = releases .. '/download/' .. tag
  vim.fn.mkdir(dir, 'p')
  for _, opt in ipairs(opts.optimize or { 'ReleaseSafe', 'ReleaseFast' }) do
    local name = ('zig-analyzer-%s-%s-%s'):format(tag, target, opt)
    local stage = tmp .. '/stage/' .. name
    vim.fn.mkdir(stage, 'p')
    sh({ 'cp', server, stage .. '/zig-analyzer' })
    sh({ 'tar', '-czf', dir .. '/' .. name .. '.tar.gz', '-C', tmp .. '/stage', name })
  end
  signer('sign', opts.key or key, dir, 'zig-analyzer ' .. (opts.comment or tag))
  if opts.latest then
    vim.fn.mkdir(releases .. '/latest', 'p')
    vim.fn.delete(releases .. '/latest/download', 'rf')
    sh({ 'cp', '-R', dir, releases .. '/latest/download' })
  end
  return dir
end

local messages = {}
vim.notify = function(msg, level)
  table.insert(messages, { msg = msg, level = level })
  print('     notify: ' .. msg)
end
local function notified(pattern)
  for _, m in ipairs(messages) do
    if m.msg:find(pattern) then return true end
  end
  return false
end

--- Runs an install to its end; returns its error, if any
local function run(opts)
  local done, result = false, nil
  opts = vim.tbl_extend('force', opts or {}, {
    on_done = function(err)
      done, result = true, err
    end,
  })
  install.install(opts)
  vim.wait(120000, function() return done end, 50)
  if not done then return 'timed out' end
  return result
end
local data = install.dir()
local function leftovers()
  for entry in vim.fs.dir(data) do
    if vim.startswith(entry, '.tmp') then return true end
  end
  return false
end

-- The install of every release target is found (`x86_64` has an underscore)
for _, t in ipairs({ 'x86_64-linux', 'aarch64-linux', 'x86_64-macos', 'aarch64-macos', 'x86_64-windows', 'aarch64-windows' }) do
  for _, opt in ipairs(install.optimize_modes) do
    local name = ('zig-analyzer-v1.2.3-rc.1-%s-%s'):format(t, opt)
    vim.fn.mkdir(data .. '/' .. name, 'p')
    sh({ 'cp', server, data .. '/' .. name .. '/zig-analyzer' })
    vim.fn.writefile({ name }, data .. '/current')
    check(select(2, install.installed()) == name, 'an install for ' .. t .. ' ' .. opt .. ' is found')
    vim.fn.delete(data .. '/' .. name, 'rf')
  end
end
vim.fn.delete(data .. '/current')
check(install.installed() == nil, 'without an install none is found')

-- Rejected installs leave nothing installed
release('v9.9.7', { key = other })
local err = run({ version = 'v9.9.7' })
check(err and err:find('signed with another key') ~= nil, 'a release signed with another key is rejected')
release('v9.9.6', { comment = 'v9.9.5' })
err = run({ version = 'v9.9.6' })
check(err and err:find('signed for v9.9.5') ~= nil, 'a release signed for another tag is rejected')
local dir = release('v9.9.4', { optimize = { 'ReleaseSafe' } })
err = run({ version = 'v9.9.4', optimize = 'ReleaseFast' })
check(err and err:find('has no zig%-analyzer%-v9%.9%.4%-') ~= nil, 'a release without the archive is rejected')
local archive = ('%s/zig-analyzer-v9.9.4-%s-ReleaseSafe.tar.gz'):format(dir, target)
local f = assert(io.open(archive, 'ab'))
f:write('x')
f:close()
err = run({ version = 'v9.9.4' })
check(err and err:find('SHA%-256 does not match') ~= nil, 'an archive with another SHA-256 is rejected')
check(install.installed() == nil, 'rejected installs install nothing')
check(not leftovers(), 'rejected installs leave no temporary directory')
err = run({ version = 'nightly' })
check(err and err:find('is not a release tag') ~= nil, 'a version that is no tag is rejected')

-- A running server from PATH is replaced by the installed one
local bin = tmp .. '/bin'
vim.fn.mkdir(bin, 'p')
sh({ 'ln', '-s', server, bin .. '/zig-analyzer' })
vim.env.PATH = bin .. ':' .. vim.env.PATH
check(select(2, install.command()) == 'PATH', 'without an install the server is that of PATH')
local project = tmp .. '/project'
vim.fn.mkdir(project, 'p')
sh({ 'cp', '-R', root .. '/../test-project/.', project })
require('zig-analyzer').setup({})
vim.cmd.edit(project .. '/src/main.zig')

--- The command line of the server process of the client attached to the current buffer, once that
--- client is not `old` and has initialized and the server of any previous client has exited
local function server_command(old)
  local client
  vim.wait(30000, function()
    client = vim.lsp.get_clients({ name = 'zig_analyzer', bufnr = 0 })[1]
    return client ~= nil and client.id ~= old and client.initialized
  end, 50)
  if not client or client.id == old then return nil end
  local servers
  vim.wait(10000, function()
    servers = {}
    for _, pid in ipairs(vim.api.nvim_get_proc_children(vim.fn.getpid())) do
      local r = vim.system({ 'ps', '-o', 'command=', '-p', tostring(pid) }, { text = true }):wait()
      local cmd = vim.trim(r.stdout or '')
      if cmd:find('zig%-analyzer') then table.insert(servers, cmd) end
    end
    return #servers == 1
  end, 100)
  if #servers ~= 1 then print('     servers: ' .. table.concat(servers, ', ')) end
  return #servers == 1 and servers[1] or nil, client
end
local cmd, client = server_command()
check(cmd == 'zig-analyzer', 'the server of PATH runs')

release('v9.9.8', {})
release('v9.9.9', { latest = true })
check(run() == nil, 'the latest release installs')
local exe, name = install.installed()
check(name == ('zig-analyzer-v9.9.9-%s-ReleaseSafe'):format(target), 'the latest release is installed')
check(exe == ('%s/%s/zig-analyzer'):format(data, name), 'it is installed in the data directory')
check(read(data .. '/current') == name .. '\n', 'it is the current install')
check(install.command() == exe, 'the installed server comes before that of PATH')
cmd, client = server_command(client and client.id)
check(cmd == exe, 'the running server restarts with the installed one')

vim.cmd('ZigAnalyzer install v9.9.8 ReleaseFast')
vim.wait(120000, function() return not install.busy end, 50)
exe, name = install.installed()
check(name == ('zig-analyzer-v9.9.8-%s-ReleaseFast'):format(target), ':ZigAnalyzer install selects a release and mode')
check(vim.fn.isdirectory(('%s/zig-analyzer-v9.9.9-%s-ReleaseSafe'):format(data, target)) == 0, 'the previous install is removed')
cmd, client = server_command(client and client.id)
check(cmd == exe, 'the running server restarts with the new install')

-- Installing the installed release again downloads nothing
vim.fn.delete(('%s/download/v9.9.8/zig-analyzer-v9.9.8-%s-ReleaseFast.tar.gz'):format(releases, target))
check(run({ version = 'v9.9.8', optimize = 'ReleaseFast' }) == nil, 'reinstalling the installed release needs no download')

local completion = vim.fn.getcompletion('ZigAnalyzer install ', 'cmdline')
check(vim.tbl_contains(completion, 'ReleaseFast') and vim.tbl_contains(completion, 'latest'), 'install arguments complete')

-- A configured `cmd` stays in use
require('zig-analyzer').setup({ cmd = { server } })
messages = {}
check(run({ version = 'v9.9.8' }) == nil, 'install works with `cmd` set')
check(notified('stays in use'), 'install says that the configured `cmd` stays in use')

-- No server at all
for _, c in ipairs(vim.lsp.get_clients({ name = 'zig_analyzer' })) do
  c:stop(true)
end
vim.fn.delete(data, 'rf')
local path = {}
for _, d in ipairs(vim.split(vim.env.PATH, ':', { trimempty = true })) do
  if vim.fn.executable(d .. '/zig-analyzer') == 0 then table.insert(path, d) end
end
vim.env.PATH = table.concat(path, ':')
check(install.command() == nil, 'without an install and PATH entry there is no server')
require('zig-analyzer').setup({ cmd = install.cmd })
messages = {}
vim.cmd.edit(project .. '/build.zig')
vim.wait(5000, function() return notified('not installed') end, 50)
check(notified(':ZigAnalyzer install'), 'without a server, opening a Zig file says how to install one')

vim.fn.delete(tmp, 'rf')
print(failures == 0 and 'all checks passed' or (failures .. ' checks failed'))
os.exit(failures == 0 and 0 or 1)
