vim9script
# Registration and requests through yegappan/lsp

import autoload 'lsp/buffer.vim' as lspbuf
import autoload 'lsp/util.vim' as lsputil

# yegappan/lsp runs one server per registration, started for the first buffer it attaches, and
# finds the root by looking the `rootSearch` entries up by path from the directory of the buffer.
# On case-insensitive file systems a lookup of `build.zig` also finds a `Build.zig` (the standard
# library's `std/Build.zig`), so `zig_analyzer#root` finds the root instead and `rootSearch` holds
# the absolute path of the entry it found, which yegappan/lsp finds from any directory. The
# server is added once there is a Zig buffer to take the root from.

var added = false

export def Register()
  for info in getbufinfo({bufloaded: 1})
    if Attaches(info.bufnr)
      AddServer(info.bufnr)
      return
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
  if !added && Attaches(bnr)
    autocmd_delete([{group: 'zig_analyzer', event: 'FileType', pattern: 'zig'}])
    AddServer(bnr)
  endif
enddef

# Whether yegappan/lsp attaches the Zig servers to buffer `bnr` (see `AddFile` in lsp/lsp.vim)
def Attaches(bnr: number): bool
  return bnr->getbufvar('&filetype') == 'zig' && bnr->getbufvar('&buftype') != 'popup'
    && !lsputil.LspUriRemote(bnr->bufname()->fnamemodify(':p'))
enddef

def AddServer(bnr: number)
  added = true
  var cmd: list<string> = zig_analyzer#cmd()
  g:LspAddServer([{
    name: g:zig_analyzer#name,
    filetype: ['zig'],
    path: cmd[0],
    args: cmd[1 :],
    rootSearch: RootSearch(bnr),
    initializationOptions: zig_analyzer#settings(),
    workspaceConfig: zig_analyzer#workspace_config(),
  }])
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
