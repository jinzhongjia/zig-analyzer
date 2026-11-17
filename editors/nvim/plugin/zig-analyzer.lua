if vim.g.loaded_zig_analyzer then return end
vim.g.loaded_zig_analyzer = true

require('zig-analyzer').create_command()
require('zig-analyzer.update').attach()
