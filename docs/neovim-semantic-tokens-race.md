# Neovim 0.12 语义着色的请求竞态

2026-10-21 记录。Neovim 0.12.6 中打开或编辑 Zig 文件时报错、语义高亮丢失。根源是 Neovim 语义 token 实现中的竞态，服务器按单个整数计算的 delta 让它表现为报错；服务器以 `fa6293d`、`0e276aa` 规避。

## 现象

打开 `build.zig`（或之后编辑）时报错：

```
vim.schedule callback: /usr/share/nvim/runtime/lua/vim/lsp/semantic_tokens.lua:425: /usr/share/nvim/runtime/lua/vim/lsp/semantic_tokens.lua:65: attempt to compare number with nil
stack traceback:
	[builtin#36]: at 0x7fb10a8a7b30
	/usr/share/nvim/runtime/lua/vim/lsp/semantic_tokens.lua:425: in function 'handler'
	/usr/share/nvim/runtime/lua/vim/lsp/client.lua:743: in function 'fn'
```

- 不报错时，窗口上下各一屏之外的语义高亮丢失，之后的编辑也在错误的 token 上增量。
- 报错后 `lsp.log` 中会有一条 `Cannot find request with id N whilst attempting to cancel`：报错中断了响应处理，在途请求的 `request_id` 没有清除，下一次 refresh 去取消这个已经完成的请求。

## 原因

行号均指 Neovim 0.12.6 的 `runtime/lua/vim/lsp/semantic_tokens.lua`。

1. 收到 `workspace/semanticTokens/refresh` 时，`mark_dirty`（747 行）只清除 `current_result.version` 与 `has_full_result`，保留 `result_id` 和 `tokens`。200 ms 防抖后 `send_request` 因为 `has_full_result` 为 false 发出 range 请求（307 行），又因为 `result_id` 还在发出 delta 请求（404 行），`previousResultId` 是刷新前的结果。
2. `has_full_result` 为 false 时 range 响应照常处理（355 行），`process_response` 把 `current_result.tokens` 换成 range 的 token（578 行）。
3. delta 响应随后到达，`process_response` 以此时的 `current_result.tokens`（541 行）为基线套用 edits，而它已经是 range 的 token，不是服务器计算 delta 时的基线。
4. 服务器的 delta 原先按单个 u32 求公共前后缀，`start`、`deleteCount` 与 `data` 的长度不一定是 5 的倍数。套用到错误的基线后数组长度不再是 5 的倍数，`tokens_to_ranges` 读到的 `data[i + 4]` 为 nil（136 行），`modifiers_from_number` 的 `while x > 0`（65 行）报错。长度恰好对齐时不报错，但客户端保存的 token 仍然是错的，例如 edits 为空时只剩 range 的 token。

服务器在项目加载与索引完成、外部文件变化、相关配置变化时，以及打开多个文档时打开、关闭或编辑文档后（编辑在防抖结束后）发出 refresh。请求在独立线程中处理，只算可见区域的 range 通常比全量快，所以 range 响应先到很常见。

另一处相关缺陷：取消在途请求时 `request_id` 被置空（450 行），而过期检查是 `if active_request.request_id and request_id ~= active_request.request_id`（523 行），已取消请求的迟到响应因此仍会被处理。服务器以 RequestCancelled 回复时 Neovim 丢弃回调，只有取消到达前已经算完的请求才会这样。

## 服务器侧的处理

- `fa6293d`：delta 按整个 token 求公共前后缀（同 rust-analyzer、clangd）。edits 套用到任何基线上都得到完整的 token，客户端不再报错。
- `0e276aa`：`requestSemanticRefresh` 写出 refresh 之后调用 `SemanticCache.retireBaselines`，此前发出的 resultId 不再作为 delta 基线，各文档的下一次 delta 请求返回全量，客户端被 range 替换过的基线不再参与计算。必须在写出之后作废：此后发出的结果都排在 refresh 之后到达客户端；先作废的话，两者之间发出的结果可能先于 refresh 到达，成为刷新后 delta 请求的基线。
- 代价：每次 refresh 之后，每个可见文档多一次全量 token 的传输；没有 refresh 介入的编辑仍然增量。
- 残留：refresh 到达之前连续发出、基于同一结果的两个 delta 请求如果都在取消到达前算完，它们迟到的响应都会被处理。服务器对同一基线只返回一次增量，若返回全量的那个先写出，增量的那个会套用到全量结果上；按整个 token 计算后不会报错，高亮错位持续到下一次全量结果。

## 复现

把下面的脚本保存到仓库之外（如 `/tmp/repro.lua`），在仓库根目录用指定的服务器运行。需要 PATH 中的 zig 能加载本项目；脚本只改缓冲区，不写盘；`XDG_STATE_HOME` 指向临时目录，不影响自己的 `lsp.log`。

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
-- 打开第二个文档：编辑的防抖结束后服务器会发 refresh
vim.defer_fn(function()
  vim.cmd('split src/main.zig')
  vim.cmd('wincmd p')
end, 1000)
-- 等项目加载完，在 build.zig 末尾附近（range 之外，最后一个 return 之前）逐行插入
for i = 1, 8 do
  vim.defer_fn(function()
    local n = vim.api.nvim_buf_line_count(build)
    vim.api.nvim_buf_set_lines(build, n - 6, n - 6, false, { ('    const zz%d = b.path("x");'):format(i) })
  end, 8000 + i * 1200)
end
-- 记录报错，并比较客户端保存的 token 与一次全量请求的结果
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

本机（Linux，Neovim 0.12.6，ReleaseSafe）上每个版本运行 3 次的结果：

| 服务器 | 报错 | 客户端最终的 token（全量为 4260 个整数） |
|---|---|---|
| `827ede2`（修改前） | 3/3 | 845 个，与全量不同 |
| `fa6293d` | 0/3 | 845～905 个，与全量不同 |
| `0e276aa` | 0/3 | 3/3 与全量相同 |

修改前的每次运行，`lsp.log` 中都有一条 `Cannot find request ... whilst attempting to cancel`；修改后没有。debug 日志中可以看到 refresh 之后 range 响应先于 delta 响应到达，修改后这些 delta 请求返回的是全量 `data`。

## 上游

- neovim/neovim#42356（`e8e914e`，2026-10-19 合入 master）修复了这些竞态：每个在途请求用独立的对象并按身份比较，丢弃已取消、被替换或已完成请求的响应；`mark_dirty` 同时清除 `result_id`，刷新后的下一次请求是全量；range 结果单独合并；解码后再次检查请求是否仍然有效。
- 2026-10-21 时 `release-0.12` 分支尚未包含这个修复。
- 服务器侧的两处处理与修复后的 Neovim 兼容：协议允许 delta 请求返回全量，代价同上。
