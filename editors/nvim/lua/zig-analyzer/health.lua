local M = {}

local function version(cmd)
  local ok, result = pcall(function() return vim.system(cmd, { text = true }):wait(5000) end)
  if not ok or result.code ~= 0 then return nil end
  return vim.trim(result.stdout)
end

function M.check()
  vim.health.start('zig-analyzer')
  if vim.fn.has('nvim-0.12') == 0 then vim.health.error('Neovim 0.12 or later is required') end

  local config = vim.lsp.config.zig_analyzer or {}
  local install = require('zig-analyzer.install')
  local cmd = type(config.cmd) == 'table' and config.cmd[1] or nil
  if config.cmd == install.cmd then
    local exe, source = install.command()
    if exe then
      vim.health.ok(('server (%s): %s (%s)'):format(source, vim.fn.exepath(exe), version({ exe, '--version' }) or 'unknown version'))
    else
      vim.health.error('zig-analyzer is not installed', { 'Run `:ZigAnalyzer install`, or set `cmd` in setup()' })
    end
  elseif not cmd then
    vim.health.info('`cmd` is a function; the server executable is not checked')
  elseif vim.fn.executable(cmd) == 1 then
    vim.health.ok(('server (`cmd`): %s (%s)'):format(vim.fn.exepath(cmd), version({ cmd, '--version' }) or 'unknown version'))
  else
    vim.health.error(('`%s` (`cmd`) is not executable'):format(cmd), { 'Fix `cmd` in setup(), or remove it and run `:ZigAnalyzer install`' })
  end

  local settings = (config.settings or {})['zig-analyzer'] or {}
  local zig = (settings.zig or {}).path or 'zig'
  if vim.fn.executable(zig) == 1 then
    local v = version({ zig, 'version' }) or 'unknown'
    if v:match('^0%.17%.[01]') then
      vim.health.ok(('zig: %s (%s)'):format(vim.fn.exepath(zig), v))
    else
      vim.health.warn(('zig %s: projects with build.zig need Zig 0.17.0 or 0.17.1'):format(v))
    end
  else
    vim.health.warn(('`%s` is not executable: projects with build.zig are not loaded'):format(zig))
  end

  local enabled = vim.lsp.is_enabled and vim.lsp.is_enabled('zig_analyzer')
  if enabled then
    vim.health.ok('zig_analyzer is enabled')
  else
    vim.health.warn('zig_analyzer is not enabled', { "Call require('zig-analyzer').setup()" })
  end
end

return M
