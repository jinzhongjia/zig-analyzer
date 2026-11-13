local M = {}

local name = 'zig_analyzer'

--- Configures and enables the server. `opts` is merged into the `vim.lsp.config` of
--- `zig_analyzer`; `opts.settings` holds the server settings, with or without the `zig-analyzer`
--- wrapper.
---@param opts? vim.lsp.Config
function M.setup(opts)
  opts = vim.deepcopy(opts or {})
  if opts.settings and opts.settings['zig-analyzer'] == nil then
    opts.settings = { ['zig-analyzer'] = opts.settings }
  end
  vim.lsp.config(name, opts)
  vim.lsp.enable(name)
  M.create_command()
end

--- Downloads and verifies a release of the server, and starts it (see `:ZigAnalyzer install`).
--- `opts.version` is a release tag (the latest release by default), `opts.optimize` `ReleaseSafe`
--- (default) or `ReleaseFast`.
---@param opts? { version?: string, optimize?: string }
function M.install(opts)
  require('zig-analyzer.install').install(opts)
end

--- Defines `:ZigAnalyzer`. `plugin/zig-analyzer.lua` calls it at startup; `setup()` calls it too,
--- for plugin managers that load the plugin after startup or add only `lua/` to 'runtimepath'
function M.create_command()
  vim.api.nvim_create_user_command('ZigAnalyzer', function(args)
    local f = M.commands[args.fargs[1] or '']
    if not f then
      vim.notify('ZigAnalyzer: unknown subcommand ' .. (args.fargs[1] or '(none)'), vim.log.levels.ERROR)
      return
    end
    f(vim.list_slice(args.fargs, 2))
  end, {
    nargs = '+',
    desc = 'zig-analyzer commands',
    complete = function(lead, line)
      local words = vim.split(line:sub(1, -#lead - 1), '%s+', { trimempty = true })
      local names = {}
      if #words <= 1 then
        names = vim.tbl_keys(M.commands)
      elseif words[2] == 'install' then
        names = { 'latest', unpack(require('zig-analyzer.install').optimize_modes) }
      end
      table.sort(names)
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, names)
    end,
  })
end

--- The zig-analyzer client of the current buffer, or else any running one
---@return vim.lsp.Client?
function M.client()
  local clients = vim.lsp.get_clients({ name = name, bufnr = 0 })
  if #clients == 0 then clients = vim.lsp.get_clients({ name = name }) end
  if #clients == 0 then
    vim.notify('zig-analyzer is not running', vim.log.levels.WARN)
    return nil
  end
  return clients[1]
end

--- Shows `lines` in a read-only scratch buffer in a split
local function show(title, lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = filetype
  pcall(vim.api.nvim_buf_set_name, buf, 'zig-analyzer://' .. title)
  vim.cmd('botright vsplit')
  vim.api.nvim_win_set_buf(0, buf)
end

local function json(result)
  return vim.split(vim.json.encode(result, { indent = '  ' }), '\n')
end

local function text(result)
  if type(result) ~= 'string' then return json(result) end
  return vim.split(result, '\n', { trimempty = true })
end

--- Sends a custom request and shows its result
local function view(title, method, params, render, filetype)
  local client = M.client()
  if not client then return end
  client:request(method, params, function(err, result)
    if err then
      vim.notify(('zig-analyzer: %s failed: %s'):format(method, err.message), vim.log.levels.ERROR)
    elseif result == nil or result == vim.NIL then
      vim.notify('zig-analyzer: the file is not known to the server', vim.log.levels.WARN)
    else
      show(title, render(result), filetype)
    end
  end, 0)
end

local function document()
  return { textDocument = vim.lsp.util.make_text_document_params(0) }
end

--- The subcommands of `:ZigAnalyzer`
M.commands = {
  status = function()
    view('status.json', 'zig-analyzer/status', nil, json, 'json')
  end,
  fileStatus = function()
    view('file-status.json', 'zig-analyzer/fileStatus', document(), json, 'json')
  end,
  syntaxTree = function()
    view('syntax-tree.txt', 'zig-analyzer/syntaxTree', document(), text, 'text')
  end,
  moduleGraph = function()
    view('module-graph.json', 'zig-analyzer/moduleGraph', nil, json, 'json')
  end,
  reloadWorkspace = function()
    local client = M.client()
    if client then client:request('zig-analyzer/reloadWorkspace', nil, function() end) end
  end,
  restart = function()
    vim.cmd('lsp restart ' .. name)
  end,
  log = function()
    vim.cmd.tabnew(vim.lsp.log.get_filename())
  end,
  install = function(args)
    require('zig-analyzer.install').command_install(args)
  end,
}

return M
