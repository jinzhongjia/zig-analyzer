const std = @import("std");
const za = @import("zig_analyzer");

const usage =
    \\用法: zig-analyzer [选项]
    \\
    \\通过 stdio 提供 Zig 语言服务（LSP）。
    \\
    \\选项:
    \\  --version   打印版本
    \\  --help      打印本帮助
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(io, za.version ++ "\n");
            return 0;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return 0;
        } else {
            std.log.err("未知参数: {s}", .{arg});
            return 1;
        }
    }

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    var writer: za.lsp.transport.Writer = .{ .io = io, .inner = &stdout.interface };

    var server: za.Server = undefined;
    server.init(io, init.gpa, &writer);
    defer server.deinit();
    return server.run(&stdin.interface);
}
