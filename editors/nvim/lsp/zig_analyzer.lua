-- Default configuration of the zig-analyzer language server, for `vim.lsp.config` /
-- `vim.lsp.enable('zig_analyzer')`.

-- Origins (`zig-analyzer/fileStatus`) of dependency library files: the Zig installation, generated
-- files, and fetched packages
local library = { zig_lib = true, generated = true, package = true }

--- Whether `dir` is a workspace folder of `client` (compared as `vim.lsp.start` does when it
--- decides to reuse a client)
local function has_folder(client, dir)
  local uri = vim.uri_from_fname(dir)
  for _, folder in ipairs(client.workspace_folders or {}) do
    if folder.uri == uri then return true end
  end
  return false
end

--- The running clients to ask about the file of `bufnr`, the client of the alternate buffer (where
--- a jump to a definition came from) first; none when a client with the workspace folder `root`
--- runs, since that one is reused
local function candidates(bufnr, root)
  local list, seen = {}, {}
  local alt = vim.fn.bufnr('#')
  local groups = {}
  if alt > 0 and alt ~= bufnr then table.insert(groups, vim.lsp.get_clients({ name = 'zig_analyzer', bufnr = alt })) end
  table.insert(groups, vim.lsp.get_clients({ name = 'zig_analyzer' }))
  for _, group in ipairs(groups) do
    for _, client in ipairs(group) do
      if not seen[client.id] and not client:is_stopped() then
        if root and has_folder(client, root) then return {} end
        seen[client.id] = true
        table.insert(list, client)
      end
    end
  end
  return list
end

--- Asks the clients in turn whether the file of `bufnr` is a dependency library file for them, and
--- calls `done` with the first that says so, or with nil. A client that does not answer within a
--- second is skipped.
local function library_owner(bufnr, clients, done)
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  local function try(i)
    local client = clients[i]
    if not client then return done(nil) end
    local answered = false
    local ok, id = client:request('zig-analyzer/fileStatus', params, function(err, result)
      if answered then return end
      answered = true
      if not err and type(result) == 'table' and library[result.origin] then return done(client) end
      try(i + 1)
    end, bufnr)
    if not ok then
      answered = true
      return try(i + 1)
    end
    vim.defer_fn(function()
      if answered then return end
      answered = true
      client:cancel_request(id)
      try(i + 1)
    end, 1000)
  end
  try(1)
end

---@type vim.lsp.Config
return {
  cmd = { 'zig-analyzer' },
  filetypes = { 'zig', 'zon' },
  -- Match directory entries by their exact names. `root_markers = { 'build.zig', '.git' }` checks
  -- paths, which on case-insensitive file systems (macOS and Windows by default) also finds the
  -- standard library's `std/Build.zig` and makes the standard library directory a workspace root.
  --
  -- A dependency library file of a running server (the standard library, a fetched package, a
  -- generated file; typically reached by going to a definition) is attached to that server. With a
  -- root of its own, another server would start without the project the file was reached from: the
  -- Zig installation of a package manager such as Homebrew lies in a git repository, and that of
  -- an official archive under no marker at all.
  root_dir = function(bufnr, on_dir)
    local root = vim.fs.root(bufnr, function(name)
      return name == 'build.zig' or name == '.git'
    end)
    local clients = candidates(bufnr, root)
    if #clients == 0 or vim.api.nvim_buf_get_name(bufnr) == '' then return on_dir(root) end
    library_owner(bufnr, clients, function(client)
      on_dir(client and client.root_dir or root)
    end)
  end,
  -- The server pulls the `zig-analyzer` section with `workspace/configuration`: the options of
  -- `zig-analyzer.default.zon` as a Lua table (`{ build = { args = { '-Dfoo' } } }`)
  settings = { ['zig-analyzer'] = vim.empty_dict() },
}
