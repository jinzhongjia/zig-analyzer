//! `@import("builtin")` 的内容由编译器按目标与编译选项生成，不在磁盘上。
//! 用与构建系统相同的参数运行 `zig <子命令> --show-builtin` 取得，按内容哈希写入缓存目录
//! （内容不变则路径不变；落盘使 goto definition 可以打开它）。
//! 另按「zig 版本 + 参数」的哈希记录对应的内容哈希，相同参数再次生成时不必启动编译器。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ZigEnv = @import("ZigEnv.zig");

const log = std.log.scoped(.builtin);

/// 生成 builtin.zig，返回其路径（调用方释放）。`args[0]` 为子命令（`build-exe` 等），其余为编译参数。
/// 编译器无法运行或参数无效时返回 null
pub fn generate(gpa: Allocator, io: Io, env: *const ZigEnv, args: []const []const u8) (Allocator.Error || Io.Cancelable)!?[]u8 {
    const zig_exe = env.zig_exe;
    const cache_dir = env.global_cache_dir;
    // 参数 → 内容哈希的记录：`<缓存>/zig-analyzer/builtin/args/<参数哈希>`
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(env.version);
    for (args) |a| {
        hasher.update(&.{0});
        hasher.update(a);
    }
    var key_buf: [16]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{x:0>16}", .{hasher.final()}) catch unreachable;
    const index_path = try std.fs.path.join(gpa, &.{ cache_dir, "zig-analyzer", "builtin", "args", key });
    defer gpa.free(index_path);
    if (try cached(gpa, io, cache_dir, index_path)) |path| return path;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, zig_exe);
    try argv.append(gpa, if (args.len != 0) args[0] else "build-obj");
    try argv.append(gpa, "--show-builtin");
    if (args.len > 1) try argv.appendSlice(gpa, args[1..]);

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            log.info("failed to run zig --show-builtin: {t}", .{err});
            return null;
        },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            log.info("zig --show-builtin failed: {s}", .{std.mem.trim(u8, result.stderr, " \n")});
            return null;
        },
        else => return null,
    }

    const hash = std.hash.Wyhash.hash(0, result.stdout);
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{x:0>16}", .{hash}) catch unreachable;
    const dir_path = try std.fs.path.join(gpa, &.{ cache_dir, "zig-analyzer", "builtin", name });
    defer gpa.free(dir_path);
    const path = try std.fs.path.join(gpa, &.{ dir_path, "builtin.zig" });
    var ok = false;
    defer if (!ok) gpa.free(path);

    // 同名文件内容必然相同：已存在则直接使用
    Io.Dir.cwd().access(io, path, .{}) catch {
        Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
            log.info("cannot create {s}: {t}", .{ dir_path, err });
            return null;
        };
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = result.stdout }) catch |err| {
            log.info("cannot write {s}: {t}", .{ path, err });
            return null;
        };
    };
    // 记录失败不影响结果：下次重新生成
    if (std.fs.path.dirname(index_path)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = name }) catch {};
    ok = true;
    return path;
}

/// 按参数记录找到的已生成文件
fn cached(gpa: Allocator, io: Io, cache_dir: []const u8, index_path: []const u8) Allocator.Error!?[]u8 {
    var name_buf: [16]u8 = undefined;
    const name = Io.Dir.cwd().readFile(io, index_path, &name_buf) catch return null;
    if (name.len != name_buf.len) return null;
    const path = try std.fs.path.join(gpa, &.{ cache_dir, "zig-analyzer", "builtin", name, "builtin.zig" });
    Io.Dir.cwd().access(io, path, .{}) catch {
        gpa.free(path);
        return null;
    };
    return path;
}

/// builtin.zig 中目标的指针位宽：由 `cpu.arch` 与 `abi` 计算（与 `std.Target.ptrBitWidth` 一致）
pub fn pointerBits(text: []const u8) ?u16 {
    const arch_name = tagAfter(text, "    .arch = .") orelse return null;
    const abi_name = tagAfter(text, "pub const abi: std.Target.Abi = .") orelse return null;
    const arch = std.meta.stringToEnum(std.Target.Cpu.Arch, arch_name) orelse return null;
    const abi = std.meta.stringToEnum(std.Target.Abi, abi_name) orelse return null;
    return std.Target.ptrBitWidth_arch_abi(arch, abi);
}

/// `prefix` 之后的标识符（到 `,` 或 `;`）
fn tagAfter(text: []const u8, prefix: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, text, prefix) orelse return null) + prefix.len;
    const end = std.mem.indexOfAnyPos(u8, text, start, ",;\n") orelse return null;
    return text[start..end];
}

test generate {
    const testing = std.testing;
    var env = ZigEnv.query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(cache);
    env.global_cache_dir = cache;

    const a = (try generate(testing.allocator, testing.io, &env, &.{ "test", "-target", "x86_64-linux", "-Ofast" })).?;
    defer testing.allocator.free(a);
    const text = try Io.Dir.cwd().readFileAlloc(testing.io, a, testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "pub const is_test = true;") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".tag = .linux") != null);
    try testing.expectEqualStrings("builtin.zig", std.fs.path.basename(a));

    // 相同参数得到相同路径（经由参数记录，不再运行编译器）；无效参数为 null
    const b = (try generate(testing.allocator, testing.io, &env, &.{ "test", "-target", "x86_64-linux", "-Ofast" })).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    try testing.expect(try generate(testing.allocator, testing.io, &env, &.{ "build-obj", "-target", "no-such-target" }) == null);

    // 指针宽度
    try testing.expectEqual(64, pointerBits(text));
    const wasm = (try generate(testing.allocator, testing.io, &env, &.{ "build-obj", "-target", "wasm32-freestanding" })).?;
    defer testing.allocator.free(wasm);
    const wasm_text = try Io.Dir.cwd().readFileAlloc(testing.io, wasm, testing.allocator, .unlimited);
    defer testing.allocator.free(wasm_text);
    try testing.expectEqual(32, pointerBits(wasm_text));
}
