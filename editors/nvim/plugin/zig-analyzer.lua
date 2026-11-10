if vim.g.loaded_zig_analyzer then return end
vim.g.loaded_zig_analyzer = true

vim.api.nvim_create_user_command('ZigAnalyzer', function(args)
  local commands = require('zig-analyzer').commands
  local f = commands[args.fargs[1] or '']
  if not f then
    vim.notify('ZigAnalyzer: unknown subcommand ' .. (args.fargs[1] or '(none)'), vim.log.levels.ERROR)
    return
  end
  f()
end, {
  nargs = 1,
  desc = 'zig-analyzer commands',
  complete = function(lead)
    local names = vim.tbl_keys(require('zig-analyzer').commands)
    table.sort(names)
    return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, names)
  end,
})
