//! 文件的来源：Zig 安装目录、生成文件、获取的依赖包、用户代码。编译上下文中的依赖库、durability、
//! 重命名、服务端监听与 workspace symbol 的范围都由这一份分类得出（分类依据见 `Server.originRules`）。

const std = @import("std");
const Vfs = @import("../base/Vfs.zig");
const Durability = @import("../db/engine.zig").Durability;
const isVirtual = @import("Server.zig").isVirtual;

pub const Origin = enum {
    /// 不在磁盘上的文档（`untitled:` 等）
    virtual,
    /// 工作区根目录外的 Zig 安装目录：标准库、`lib/compiler` 等
    zig_lib,
    /// 生成文件：全局缓存与各项目 maker 使用的本地缓存
    generated,
    /// 获取的依赖包
    package,
    /// 用户代码：工作区根目录下（不含其中的 `.zig-cache`、`zig-pkg`），或在根目录外但属于某个项目的模块
    /// （以路径加入的模块、`--fork` 指定的包）
    user,
    /// 其余文件：根目录外、不属于任何项目，或位于根目录下的 `.zig-cache`、`zig-pkg` 中
    other,

    /// 依赖库：内容不由用户编辑
    pub fn isLibrary(o: Origin) bool {
        return switch (o) {
            .zig_lib, .generated, .package => true,
            .virtual, .user, .other => false,
        };
    }

    /// 文件内容的变化频率：Zig 安装目录与获取的依赖包（按哈希寻址）不变，生成文件随构建更新，其余经常变化
    pub fn durability(o: Origin) Durability {
        return switch (o) {
            .zig_lib, .package => .high,
            .generated => .medium,
            .virtual, .user, .other => .low,
        };
    }
};

/// 分类的依据。字符串由创建者持有
pub const Rules = struct {
    /// `zig env` 的 lib_dir 与 global_cache_dir；zig 环境未知时为 null
    zig_lib: ?[]const u8 = null,
    global_cache: ?[]const u8 = null,
    /// 工作区根目录
    roots: []const []const u8 = &.{},
    /// 各项目 maker 使用的本地缓存目录（它包含构建根目录时无法区分生成文件与项目文件，不在其中）
    local_caches: []const []const u8 = &.{},
    /// 各项目获取的依赖包的根目录
    packages: []const []const u8 = &.{},
};

/// `path` 的来源；`in_project` 为文件属于某个项目的模块图，只影响根目录外的文件。依次判断：依赖包、生成文件
/// （在根目录下也是）、根目录下的用户代码、Zig 安装目录（在根目录下时是 Zig 自身的开发者在编辑它，属于用户代码）、
/// 项目的模块
pub fn classify(vfs: *const Vfs, rules: Rules, path: []const u8, in_project: bool) Origin {
    if (isVirtual(path)) return .virtual;
    for (rules.packages) |p| if (vfs.isUnder(path, p)) return .package;
    for (rules.local_caches) |c| if (vfs.isUnder(path, c)) return .generated;
    if (rules.global_cache) |c| if (vfs.isUnder(path, c)) return .generated;
    var in_root = false;
    for (rules.roots) |root| {
        if (path.len <= root.len or !vfs.isUnder(path, root)) continue;
        in_root = true;
        const rest = path[root.len..];
        const sub = if (std.fs.path.isSep(rest[0])) rest[1..] else rest;
        // maker 默认的本地缓存与包目录：改用别处（`--cache-dir`、`--pkg-dir`）时这里是过时的副本
        if (std.mem.startsWith(u8, sub, ".zig-cache") or std.mem.startsWith(u8, sub, "zig-pkg")) continue;
        return .user;
    }
    if (rules.zig_lib) |l| if (vfs.isUnder(path, l)) return .zig_lib;
    if (in_root) return .other;
    return if (in_project) .user else .other;
}

const testing = std.testing;
const native = @import("../util/test_path.zig").native;

test classify {
    var vfs: Vfs = .init(testing.io, testing.allocator);
    defer vfs.deinit();
    const rules: Rules = .{
        .zig_lib = native("/zig/lib"),
        .global_cache = native("/home/.cache/zig"),
        .roots = &.{native("/ws")},
        .local_caches = &.{ native("/ws/.zig-cache"), native("/elsewhere/cache") },
        .packages = &.{ native("/ws/zig-pkg/foo-1.0.0-hash"), native("/pkgs/bar-hash") },
    };
    const Case = struct { []const u8, bool, Origin };
    const cases = [_]Case{
        .{ native("/zig/lib/std/std.zig"), true, .zig_lib },
        .{ native("/home/.cache/zig/b/builtin.zig"), false, .generated },
        .{ native("/ws/.zig-cache/c/options.zig"), true, .generated },
        .{ native("/elsewhere/cache/c/options.zig"), true, .generated },
        .{ native("/ws/zig-pkg/foo-1.0.0-hash/src/root.zig"), true, .package },
        .{ native("/pkgs/bar-hash/src/root.zig"), true, .package },
        .{ native("/ws/src/main.zig"), true, .user },
        // 根目录下不在模块图中的文件也是用户代码
        .{ native("/ws/scripts/gen.zig"), false, .user },
        // 改用别处的包目录后留在根目录下的旧副本
        .{ native("/ws/zig-pkg/stale-hash/src/root.zig"), true, .other },
        // 根目录外、以路径加入项目的模块
        .{ native("/libs/shared/src/root.zig"), true, .user },
        .{ native("/tmp/scratch.zig"), false, .other },
    };
    for (cases) |c| {
        testing.expectEqual(c[2], classify(&vfs, rules, c[0], c[1])) catch |err| {
            std.debug.print("classify {s}\n", .{c[0]});
            return err;
        };
    }
    // Zig 安装目录位于工作区根目录下：在开发 Zig 自身
    const in_root: Rules = .{ .zig_lib = native("/ws/lib"), .roots = &.{native("/ws")} };
    try testing.expectEqual(.user, classify(&vfs, in_root, native("/ws/lib/std/std.zig"), true));
    // zig 环境未知：只按根目录与项目分类
    try testing.expectEqual(.other, classify(&vfs, .{}, native("/zig/lib/std/std.zig"), false));
}

test "durability follows the origin" {
    try testing.expectEqual(.high, Origin.zig_lib.durability());
    try testing.expectEqual(.high, Origin.package.durability());
    try testing.expectEqual(.medium, Origin.generated.durability());
    try testing.expectEqual(.low, Origin.user.durability());
    try testing.expectEqual(.low, Origin.other.durability());
}
