# 批量校验的项目清单

`docs/design.md` §5.3 中批量校验所用的 97 个 Zig 0.17.0 项目。提交为 2026-10-19 克隆时默认分支的最新提交；测量文件为根项目（不含自带 `build.zig` 的子目录、测试与示例）中成员访问最多的文件，只有构建脚本的 C 库为 `build.zig`。

复现：克隆并检出表中的提交，在项目根目录运行 `zig build --fetch` 取得依赖，再在本仓库中对每个项目运行

```
BENCH_QUICK=1 BENCH_CHECK=40 BENCH_COMPLETE=40 BENCH_REFS=20 zig build bench -Doptimize=ReleaseSafe -- <项目根目录> <测量文件>
```

kristoff-it/zine 的 `build.zig` 以 `git describe` 求版本号，需要完整的提交历史与 tag，浅克隆时构建配置失败。

| 仓库 | 提交 | 测量文件 |
|---|---|---|
| https://codeberg.org/GasInfinity/zitrus | `35cb3ecddb5a` | `src/horizon/Io/Storage.zig` |
| https://codeberg.org/hgrsd/zopt | `d78b41e94ea1` | `src/Zopt.zig` |
| https://codeberg.org/lipfang/weebsocket | `e2bad78e9a2d` | `src/message/writer.zig` |
| https://codeberg.org/lipfang/zigcord | `1134f28afe5d` | `src/rest/endpoints/channel.zig` |
| https://github.com/ATTron/astroz | `c4aed0107702` | `src/Sdp4.zig` |
| https://github.com/Arwalk/zig-protobuf | `e9e18c7664b8` | `bootstrapped-generator/google/protobuf.pb.zig` |
| https://github.com/CogitatorTech/chilli | `8dd62798ae24` | `src/chilli/command.zig` |
| https://github.com/CogitatorTech/ordered | `b7fbf8eeef92` | `src/ordered/btree_map.zig` |
| https://github.com/CogitatorTech/zigformer | `eac1bebec50d` | `src/zigformer/llm.zig` |
| https://github.com/Element0Lang/element-0 | `641a0f64f407` | `src/elz/compiler.zig` |
| https://github.com/Hejsil/zig-clap | `05faf3905e85` | `clap.zig` |
| https://github.com/JakubSzark/zig-string | `dd08a9de08da` | `zig-string.zig` |
| https://github.com/KurtWagner/zlinter | `00882eaf9176` | `src/lib/session/LintSession.zig` |
| https://github.com/MasterQ32/zig-args | `ad3c89ecdb29` | `args.zig` |
| https://github.com/OrlovEvgeny/serde.zig | `618752961e7f` | `src/formats/yaml/parser.zig` |
| https://github.com/PixelGuys/Cubyz | `42dda1838e6e` | `src/graphics.zig` |
| https://github.com/StrobeLabs/eth.zig | `0c04a8988e4b` | `src/provider.zig` |
| https://github.com/TheAlgorithms/Zig | `86c96a3fd0da` | `dataStructures/lruCache.zig` |
| https://github.com/ZigEmbeddedGroup/microzig | `cefa3e92fa1c` | `tools/generate_linker_script.zig` |
| https://github.com/ZigEmbeddedGroup/serial | `25b58d0ea62f` | `src/serial.zig` |
| https://github.com/andrewrk/ffmpeg | `51d347c18f7c` | `av.zig` |
| https://github.com/andrewrk/libmp3lame | `b2322045e93d` | `build.zig` |
| https://github.com/andrewrk/libogg | `aa85a1820fd5` | `build.zig` |
| https://github.com/andrewrk/libvorbis | `b13b88185e15` | `build.zig` |
| https://github.com/andrewrk/pulseaudio | `b6ff9a7da575` | `bindings.zig` |
| https://github.com/bcrist/Zig-TempAllocator | `e922e2aaa4c6` | `Temp_Allocator.zig` |
| https://github.com/blockblaz/ssz.zig | `395121c90379` | `src/lib.zig` |
| https://github.com/charlesrocket/ghext | `7518122b1852` | `src/ghext.zig` |
| https://github.com/cztomsik/tokamak | `a08b31ac2087` | `src/container.zig` |
| https://github.com/deatil/zig-dotenv | `b9061f81dc2b` | `src/dotenv.zig` |
| https://github.com/deatil/zig-jwt | `82e6d23def2a` | `pkg/ecdsa/group.zig` |
| https://github.com/deatil/zig-md2 | `903dce383259` | `src/md2.zig` |
| https://github.com/deatil/zig-md4 | `f70524a47b5a` | `src/md4.zig` |
| https://github.com/deatil/zig-paseto | `54104c831c3c` | `src/token.zig` |
| https://github.com/deatil/zig-rsa | `9e4355327b76` | `src/rsa.zig` |
| https://github.com/deatil/zig-sm3 | `2d7ae4cfcc60` | `src/sm3.zig` |
| https://github.com/deatil/zig-time | `2cb1717067ba` | `src/time.zig` |
| https://github.com/deatil/zig-totp | `8665793b47aa` | `src/time.zig` |
| https://github.com/deatil/zpem | `469d74693dc0` | `src/zpem.zig` |
| https://github.com/deckarep/ziglang-set | `38180556c78f` | `src/hash_set.zig` |
| https://github.com/eoan-ermine/zig-strparse | `2005b39c5ad8` | `src/root.zig` |
| https://github.com/g41797/mailbox | `833c7bca1fad` | `src/mailbox.zig` |
| https://github.com/guanchzhou/zig-diffuse | `a392d7489506` | `src/cli.zig` |
| https://github.com/guanchzhou/zig-hilbert | `a14886e82226` | `src/s2.zig` |
| https://github.com/guanchzhou/zig-klient | `8f74f05bfa54` | `src/k8s/client.zig` |
| https://github.com/guanchzhou/zig-lsh | `12956a9804a9` | `src/cli.zig` |
| https://github.com/guanchzhou/zig-planar | `809d7fa11414` | `src/planarity.zig` |
| https://github.com/guanchzhou/zig-pq | `883bfe9a9131` | `src/cli.zig` |
| https://github.com/guanchzhou/zig-rabitq | `f786dd15d686` | `src/index.zig` |
| https://github.com/guanchzhou/zig-select | `07b6e195b53a` | `src/cli.zig` |
| https://github.com/hendriknielaender/zBench | `f12a2262bcd9` | `src/allocators/shuffling_allocator.zig` |
| https://github.com/here-Leslie-Lau/zlist | `cf2652d24b99` | `src/render.zig` |
| https://github.com/jiacai2050/zig-curl | `9c0f1d211ad2` | `libs/curl.zig` |
| https://github.com/jiacai2050/zigcli | `ae972e756c37` | `src/pretty-table.zig` |
| https://github.com/karlseguin/http.zig | `e8272bfd5727` | `src/httpz.zig` |
| https://github.com/karlseguin/websocket.zig | `f2b3bad68755` | `src/server/server.zig` |
| https://github.com/kassane/openssl-zig | `41cd1e69926f` | `build.zig` |
| https://github.com/kooparse/zalgebra | `b5ebfef29a76` | `src/quaternion.zig` |
| https://github.com/kristoff-it/zine | `6c9782957f46` | `src/root.zig` |
| https://github.com/ktarasov/check_links | `1be30ccf78d1` | `src/http_head_client.zig` |
| https://github.com/llllOllOOll/spider | `bd923a260db4` | `src/ws/hub.zig` |
| https://github.com/malcolmstill/zware | `83842277031a` | `src/instance/vm.zig` |
| https://github.com/meszmate/zigzag | `15db0f7e12dd` | `src/terminal/terminal.zig` |
| https://github.com/midasdf/zt | `85f5b526a34a` | `src/vt.zig` |
| https://github.com/muhammad-fiaz/args.zig | `cf1ea753f017` | `src/args.zig` |
| https://github.com/muhammad-fiaz/httpx.zig | `b38b4b18af5f` | `src/web/templates/templateRenderer.zig` |
| https://github.com/muhammad-fiaz/logly.zig | `583255ee5530` | `src/sink.zig` |
| https://github.com/nDimensional/zig-flatbuffers | `752ae1fa7e85` | `src/flatbuffers.zig` |
| https://github.com/nDimensional/zig-sqlite | `0c79b81d7f93` | `src/sqlite.zig` |
| https://github.com/neurocyte/flow | `ee547b0a462d` | `src/tui/mainview.zig` |
| https://github.com/neurocyte/thespian | `1cc609efc48a` | `src/subprocess_windows.zig` |
| https://github.com/nurulhudaapon/zx | `e1f3268e8ff3` | `src/lsp/data/elements.zig` |
| https://github.com/orhun/linuxwave | `ecc2ee9cde7d` | `src/main.zig` |
| https://github.com/pedronaugusto/chronicle | `9902469496bd` | `src/journal/Log.zig` |
| https://github.com/pedronaugusto/lookout | `8a42c1b1e047` | `src/backend/FsEvents.zig` |
| https://github.com/pedronaugusto/morse | `ac2dc93141aa` | `src/key.zig` |
| https://github.com/pedronaugusto/strand | `3f25dff5fc9c` | `src/core/decode.zig` |
| https://github.com/peymanmortazavi/csv-zero | `a687d508e57b` | `src/iterator.zig` |
| https://github.com/raysan5/raylib | `2e66d4080c15` | `build.zig` |
| https://github.com/rockorager/libvaxis | `d4c3b3666e0c` | `src/Vaxis.zig` |
| https://github.com/rockorager/zeit | `06bb7b462b42` | `src/zeit.zig` |
| https://github.com/ross-weir/logex | `cca4ff19cb17` | `src/filter/env.zig` |
| https://github.com/shaik-abdul-thouhid/ezi-code | `9a8106d39dc9` | `src/generate.zig` |
| https://github.com/shaik-abdul-thouhid/ezi-gex | `65d5477eca68` | `src/core/hir.zig` |
| https://github.com/tammoippen/zig-plotille | `652ed423bb33` | `src/canvas.zig` |
| https://github.com/tardy-org/zzz | `3dadef97aba2` | `src/http/Server.zig` |
| https://github.com/user529/zora | `41a4fbd54c29` | `src/worker.zig` |
| https://github.com/webui-dev/zig-webui | `e89087c3e984` | `src/webui.zig` |
| https://github.com/xcaeser/glob.zig | `a8378b0abd6f` | `src/glob.zig` |
| https://github.com/xcaeser/zig-dotenv | `bea69b5e2bdd` | `src/dotenv.zig` |
| https://github.com/xcaeser/zli | `52a3773e7b82` | `src/zli.zig` |
| https://github.com/zPSP-Dev/Zig-PSP | `1b43abfcf032` | `src/utils/Io.zig` |
| https://github.com/zigimg/zigimg | `c8ab20d57487` | `src/color.zig` |
| https://github.com/ziglibs/known-folders | `6da0d0c41b78` | `known-folders.zig` |
| https://github.com/zigtools/zls | `4e83599939e9` | `src/analysis.zig` |
| https://github.com/zoptia/zoptia0regex | `8e8f2256e475` | `src/parse.zig` |
| https://tangled.org/zat.dev/zat | `e4bf84d234cd` | `src/internal/repo/mst.zig` |
