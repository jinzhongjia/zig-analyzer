# Neovim 0.12 semantic tokens request race

Recorded on 2026-10-21. In Neovim 0.12.6, opening or editing a Zig file raises an error and semantic highlighting is lost. The root cause is a race in Neovim's semantic token implementation; the server's deltas, computed over individual integers, made it surface as an error. The server works around it in `fa6293d` and `0e276aa`.

## Symptoms

Opening `build.zig` (or editing it afterwards) raises:

```
vim.schedule callback: /usr/share/nvim/runtime/lua/vim/lsp/semantic_tokens.lua:425: /usr/share/nvim/runtime/lua/vim/lsp/semantic_tokens.lua:65: attempt to compare number with nil
stack traceback:
	[builtin#36]: at 0x7fb10a8a7b30
	/usr/share/nvim/runtime/lua/vim/lsp/semantic_tokens.lua:425: in function 'handler'
	/usr/share/nvim/runtime/lua/vim/lsp/client.lua:743: in function 'fn'
```

- When no error is raised, semantic highlighting beyond one screen above and below the window is lost, and later edits are applied as deltas on top of the wrong tokens.
- After the error, `lsp.log` contains a `Cannot find request with id N whilst attempting to cancel` entry: the error interrupted response handling, so the `request_id` of the in-flight request was not cleared, and the next refresh tries to cancel this already completed request.

## Cause

All line numbers refer to `runtime/lua/vim/lsp/semantic_tokens.lua` in Neovim 0.12.6.

1. On `workspace/semanticTokens/refresh`, `mark_dirty` (line 747) clears only `current_result.version` and `has_full_result`, and keeps `result_id` and `tokens`. After the 200 ms debounce, `send_request` sends a range request because `has_full_result` is false (line 307), and also a delta request because `result_id` is still set (line 404), whose `previousResultId` is the result from before the refresh.
2. While `has_full_result` is false, the range response is processed as usual (line 355): `process_response` replaces `current_result.tokens` with the range tokens (line 578).
3. The delta response arrives next, and `process_response` applies the edits with the current `current_result.tokens` (line 541) as the baseline; by now these are the range tokens, not the baseline the server computed the delta against.
4. The server used to compute the common prefix and suffix of a delta over individual u32 values, so `start`, `deleteCount`, and the length of `data` were not necessarily multiples of 5. Applied to the wrong baseline, the array length is no longer a multiple of 5: `tokens_to_ranges` reads `data[i + 4]` as nil (line 136), and the `while x > 0` in `modifiers_from_number` (line 65) raises the error. When the length happens to stay aligned there is no error, but the tokens the client keeps are still wrong; for example, when the edits are empty, only the range tokens remain.

The server sends a refresh when project loading and indexing finish, when external files change, and when relevant configuration changes, and also, while several documents are open, after a document is opened, closed, or edited (for edits, once the debounce ends). Requests are handled on separate threads, and a range request that covers only the visible area is usually faster than a full one, so it is common for the range response to arrive first.

Another related defect: canceling an in-flight request sets `request_id` to nil (line 450), while the staleness check is `if active_request.request_id and request_id ~= active_request.request_id` (line 523), so a late response to a canceled request is still processed. When the server replies with RequestCancelled, Neovim drops the callback, so this happens only to requests that were already computed before the cancellation arrived.

## Server-side workaround

- `fa6293d`: deltas compute the common prefix and suffix over whole tokens (as rust-analyzer and clangd do). Applying the edits to any baseline yields whole tokens, so the client no longer raises the error.
- `0e276aa`: after writing the refresh, `requestSemanticRefresh` calls `SemanticCache.retireBaselines`, so resultIds sent before it no longer serve as delta baselines: the next delta request of each document returns the full result, and the client's baseline that was replaced by range tokens no longer takes part in the computation. The baselines must be retired after the write: every result sent afterwards reaches the client after the refresh; if they were retired first, a result sent between the two could reach the client before the refresh and become the baseline of a delta request after the refresh.
- Cost: after each refresh, every visible document transfers its full tokens one extra time; edits without an intervening refresh stay incremental.
- Remaining issue: if two delta requests based on the same result are sent back to back before the refresh arrives, and both finish before the cancellation arrives, both late responses are processed. The server returns an incremental result only once per baseline; if the one returning the full result is written first, the incremental one is applied on top of the full result. With whole-token deltas this no longer raises an error, but the highlighting stays misplaced until the next full result.

## Reproduction

Save the script below outside the repository (e.g. `/tmp/repro.lua`) and run it from the repository root with the server to test. The zig in PATH must be able to load this project. The script only changes the buffer and never writes to disk; `XDG_STATE_HOME` points to a temporary directory, so your own `lsp.log` is not affected.

```
XDG_STATE_HOME=$(mktemp -d) ZA_BIN=zig-out/bin/zig-analyzer OUT=/tmp/za-semantic-repro.txt \
  timeout 90 nvim --headless -u /tmp/repro.lua build.zig
```

```lua
vim.o.lines = 50
vim.o.columns = 160
vim.lsp.log.set_level('debug')
vim.lsp.config('zig_analyzer', {
  cmd = { vim.fn.fnamemodify(os.getenv('ZA_BIN') or 'zig-out/bin/zig-analyzer', ':p') },
  filetypes = { 'zig' },
  root_dir = function(bufnr, on_dir) on_dir(vim.fs.root(bufnr, 'build.zig')) end,
})
vim.lsp.enable('zig_analyzer')

local out = assert(io.open(os.getenv('OUT') or '/tmp/za-semantic-repro.txt', 'w'))
local build = vim.api.nvim_get_current_buf()
-- Open a second document: the server sends a refresh once the debounce of an edit ends
vim.defer_fn(function()
  vim.cmd('split src/main.zig')
  vim.cmd('wincmd p')
end, 1000)
-- Once the project has loaded, insert lines one by one near the end of build.zig (outside the range, before the last return)
for i = 1, 8 do
  vim.defer_fn(function()
    local n = vim.api.nvim_buf_line_count(build)
    vim.api.nvim_buf_set_lines(build, n - 6, n - 6, false, { ('    const zz%d = b.path("x");'):format(i) })
  end, 8000 + i * 1200)
end
-- Record errors, and compare the tokens the client keeps with the result of a full request
vim.defer_fn(function()
  out:write(vim.fn.execute('messages'), '\n')
  local client = vim.lsp.get_clients({ name = 'zig_analyzer' })[1]
  local state = vim.lsp.semantic_tokens.__STHighlighter.active[build].client_state[client.id]
  local have = state.current_result.tokens or {}
  local res = client:request_sync('textDocument/semanticTokens/full',
    { textDocument = vim.lsp.util.make_text_document_params(build) }, 5000, build)
  local want = res.result.data
  out:write(('have %d, want %d, equal=%s\n'):format(#have, #want, tostring(vim.deep_equal(have, want))))
  vim.cmd('qa!')
end, 8000 + 8 * 1200 + 5000)
```

Results of 3 runs of each version on a local machine (Linux, Neovim 0.12.6, ReleaseSafe):

| Server | Errors | Final tokens on the client (the full result has 4260 integers) |
|---|---|---|
| `827ede2` (before the changes) | 3/3 | 845, different from the full result |
| `fa6293d` | 0/3 | 845-905, different from the full result |
| `0e276aa` | 0/3 | 3/3 identical to the full result |

Before the changes, every run logged a `Cannot find request ... whilst attempting to cancel` entry in `lsp.log`; after the changes, none did. The debug log shows the range response arriving before the delta response after a refresh, and after the changes these delta requests return the full `data`.

## Upstream

- neovim/neovim#42356 (`e8e914e`, merged into master on 2026-10-19) fixes these races: each in-flight request is a separate object compared by identity, and responses to canceled, superseded, or completed requests are dropped; `mark_dirty` also clears `result_id`, so the first request after a refresh is a full request; range results are merged separately; and after decoding, the request is checked again for whether it is still valid.
- As of 2026-10-21, the `release-0.12` branch does not include this fix yet.
- Both server-side changes are compatible with the fixed Neovim: the protocol allows a delta request to return the full result, at the cost described above.
