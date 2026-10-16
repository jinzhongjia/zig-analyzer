# 成员访问的剩余缺口

97 个 Zig 0.17.0 库的 declaration 对拍中，构建图正常时仍有少量成员访问解析不出（见 `docs/design.md` §5.3）。
以下是尚未处理的几类，按计划的处理顺序排列。

## 1. 泛型代码没有具体实例

`anytype` / `comptime T: type` 参数上的成员访问（`writer.writeAll`、`Handler.handle`、`T.parse`）只能在调用点的实例中求出。
推导已经从调用点取实例（最多追溯 3 层、64 个实例），余下分两种：

- **有调用点但没有用上**：deatil 系列的 `assertEqualHash(comptime Hasher: anytype, ...)`、zig-plotille 中经多层 `anytype` 传递的 `writer`。
  先查清是调用点跨文件、位于测试块，还是超过了追溯层数，按调用点推导的漏洞修复。
- **工作区内没有调用点**：http.zig、websocket.zig 等以用户的 Handler 为参数的框架，编译器在实例化之前同样不知道类型。
  不按名字猜测候选（会给查找引用与重命名带来误报）；考虑以仓库中示例与测试的实例化（已有模块归属）作为调用点。

## 2. `@cImport`

raylib 示例的 `rl.InitWindow` 等。需要以构建图中模块的 include 路径与宏运行 translate-c 并缓存结果（按头文件内容失效）。
构建系统中的 `addTranslateC` 已经作为生成文件处理，所以优先级最低。

## 3. 经函数返回类型推出的、按目标选择的类型

serial 的 `var settings = try std.posix.tcgetattr(fd); settings.cflag.CCTS_OFLOW`：`settings` 的类型来自返回类型
`termios`（`posix.termios = system.termios`），`CCTS_OFLOW` 只在 macOS 的 `std.c.tc_cflag_t` 中存在。
现有的其他配置查找只覆盖字段类型、类型标注与 `X.Y.init()` 形式的初始化；需要沿函数返回类型与字段链收集各配置下的类型。

## 4. comptime 生成的类型的字段没有声明位置

zig-clap 的 `res.args.aa` 由 `@Struct` 按 comptime 解析的帮助文本生成，补全与 hover 已经正确，但跳转没有目标。
可以考虑在构造类型时记录字段名的来源（字符串字面量中的位置），跳转到帮助文本中的 `--aa`。
