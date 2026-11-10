-- Default configuration of the zig-analyzer language server, for `vim.lsp.config` /
-- `vim.lsp.enable('zig_analyzer')`.

---@type vim.lsp.Config
return {
  cmd = { 'zig-analyzer' },
  filetypes = { 'zig', 'zon' },
  -- Match directory entries by their exact names. `root_markers = { 'build.zig', '.git' }` checks
  -- paths, which on case-insensitive file systems (macOS and Windows by default) also finds the
  -- standard library's `std/Build.zig` and makes the standard library directory a workspace root.
  root_dir = function(bufnr, on_dir)
    on_dir(vim.fs.root(bufnr, function(name)
      return name == 'build.zig' or name == '.git'
    end))
  end,
  -- The server pulls the `zig-analyzer` section with `workspace/configuration`: the options of
  -- `zig-analyzer.default.zon` as a Lua table (`{ build = { args = { '-Dfoo' } } }`)
  settings = { ['zig-analyzer'] = vim.empty_dict() },
}
