vim9script
# Registration and requests through yegappan/lsp

import autoload 'lsp/buffer.vim' as lspbuf
import autoload 'lsp/util.vim' as lsputil

export def Register()
  var cmd: list<string> = zig_analyzer#cmd()
  g:LspAddServer([{
    name: g:zig_analyzer#name,
    filetype: ['zig'],
    path: cmd[0],
    args: cmd[1 :],
    # yegappan/lsp looks these up by path (see `zig_analyzer#root` for what that means on
    # case-insensitive file systems)
    rootSearch: ['build.zig', '.git/'],
    initializationOptions: zig_analyzer#settings(),
    workspaceConfig: zig_analyzer#workspace_config(),
  }])
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
