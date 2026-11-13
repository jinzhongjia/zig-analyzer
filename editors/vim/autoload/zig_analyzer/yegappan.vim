vim9script
# Registration and requests through yegappan/lsp

import autoload 'lsp/buffer.vim' as lspbuf
import autoload 'lsp/util.vim' as lsputil

# yegappan/lsp runs one server per registration, started for the first buffer it attaches, and
# finds the root by looking the `rootSearch` entries up by path from the directory of the buffer.
# On case-insensitive file systems a lookup of `build.zig` also finds a `Build.zig` (the standard
# library's `std/Build.zig`), so `zig_analyzer#root` finds the root instead and `rootSearch` holds
# the absolute path of the entry it found, which yegappan/lsp finds from any directory. The
# server is added once there is a Zig buffer to take the root from and a server to run.

var added = false
# The server object of yegappan/lsp (a copy of the registered dictionary), whose `path` and
# `args` it starts the server with
var lsp_server: dict<any> = {}

export def Register()
  for info in getbufinfo({bufloaded: 1})
    if Attaches(info.bufnr)
      if AddServer(info.bufnr)
        return
      endif
      break
    endif
  endfor
  autocmd_add([{
    group: 'zig_analyzer',
    event: 'FileType',
    pattern: 'zig',
    cmd: 'call zig_analyzer#yegappan#OnZig(str2nr(expand("<abuf>")))',
  }])
enddef

export def OnZig(bnr: number)
  if !added && Attaches(bnr) && AddServer(bnr)
    autocmd_delete([{group: 'zig_analyzer', event: 'FileType', pattern: 'zig'}])
  endif
enddef

# Whether yegappan/lsp attaches the Zig servers to buffer `bnr` (see `AddFile` in lsp/lsp.vim)
def Attaches(bnr: number): bool
  return bnr->getbufvar('&filetype') == 'zig' && bnr->getbufvar('&buftype') != 'popup'
    && !lsputil.LspUriRemote(bnr->bufname()->fnamemodify(':p'))
enddef

# Adds the server, with the root of buffer `bnr`; false when there is no server to run
def AddServer(bnr: number): bool
  var cmd: list<string> = zig_analyzer#cmd()
  if cmd->empty()
    zig_analyzer#missing()
    return false
  endif
  added = true
  g:LspAddServer([{
    name: g:zig_analyzer#name,
    filetype: ['zig'],
    path: cmd[0],
    args: cmd[1 :],
    rootSearch: RootSearch(bnr),
    initializationOptions: zig_analyzer#settings(),
    workspaceConfig: zig_analyzer#workspace_config(),
  }])
  # Adding it attaches it to the Zig buffers at once
  for s in lspbuf.BufLspServersGet(bnr)
    if !s->empty() && s.name == g:zig_analyzer#name
      lsp_server = s
    endif
  endfor
  return true
enddef

# After `:ZigAnalyzer install`: adds the server if there was none to add, else makes the server
# start the installed one, and restarts it in a window of a Zig buffer it is attached to
export def Installed()
  if !added
    for bnr in [bufnr()] + getbufinfo({bufloaded: 1})->map((_, info) => info.bufnr)
      if Attaches(bnr)
        if AddServer(bnr)
          autocmd_delete([{group: 'zig_analyzer', event: 'FileType', pattern: 'zig'}])
        endif
        return
      endif
    endfor
    return
  endif
  if lsp_server->empty()
    return
  endif
  var cmd: list<string> = zig_analyzer#cmd()
  lsp_server.path = cmd[0]
  lsp_server.args = cmd[1 :]
  if !lsp_server.running
    return
  endif
  for winid in [win_getid()] + getwininfo()->map((_, info) => info.winid)
    var bnr: number = winbufnr(winid)
    if bnr->getbufvar('&filetype') == 'zig' && Serves(bnr)
      win_execute(winid, 'call zig_analyzer#yegappan#Restart()')
      return
    endif
  endfor
  lsputil.InfoMsg('zig-analyzer: the installed server starts with `:ZigAnalyzer restart` in a Zig buffer')
enddef

# Whether the server is attached to buffer `bnr`
def Serves(bnr: number): bool
  for s in lspbuf.BufLspServersGet(bnr)
    if s is lsp_server
      return true
    endif
  endfor
  return false
enddef

# The `rootSearch` of the root of buffer `bnr`. Empty without a root, which leaves the root to
# yegappan/lsp (the current directory for the files below it, or the directory of the file).
def RootSearch(bnr: number): list<string>
  var entry: string = zig_analyzer#root_entry(bnr->bufname())
  return entry->empty() ? [] : [entry]
enddef

# `LspServer restart` starts the server again for the current buffer, with the root it finds
# from `rootSearchFiles` (the `rootSearch` of the server): point it at the root of that buffer
export def Restart()
  var server: dict<any> = lspbuf.CurbufGetServerByName(g:zig_analyzer#name)
  if !server->empty()
    server.rootSearchFiles = RootSearch(bufnr())
  endif
  :LspServer restart
enddef

export def Request(method: string, params: any, Callback: func)
  var server: dict<any> = lspbuf.CurbufGetServerByName(g:zig_analyzer#name)
  if server->empty() || !server.running
    Callback(null, {message: 'zig-analyzer is not running for this buffer'})
    return
  endif
  server.rpc_a(method, params, (_, result: any, error: dict<any>) => {
    Callback(result, error)
  })
enddef

export def Uri(bnr: number): string
  return lsputil.LspBufnrToUri(bnr)
enddef

defcompile
