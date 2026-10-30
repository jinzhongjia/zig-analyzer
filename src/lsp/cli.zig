//! Command-line arguments of the server executable.

const std = @import("std");

pub const usage =
    \\Usage: zig-analyzer [options]
    \\
    \\Zig language server (LSP) over stdio.
    \\
    \\Options:
    \\  --version                  print version
    \\  --help                     print this help
    \\  --stdio                    communicate over stdio (the only transport)
    \\  --clientProcessId <pid>    the client's process id; the server exits with the
    \\                             client process given in `initialize`
    \\
;

pub const Command = union(enum) {
    /// Serve LSP over stdio
    serve,
    version,
    help,
    /// The argument is not accepted
    invalid: Invalid,
};

pub const Invalid = struct {
    arg: []const u8,
    reason: enum { unknown, unsupported_transport, missing_process_id, invalid_process_id },

    pub fn format(i: Invalid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (i.reason) {
            .unknown => try w.print("unknown argument: {s}", .{i.arg}),
            .unsupported_transport => try w.print("unsupported transport: {s} (only --stdio is supported)", .{i.arg}),
            .missing_process_id => try w.print("{s} needs a process id", .{i.arg}),
            .invalid_process_id => try w.print("invalid process id: {s}", .{i.arg}),
        }
    }
};

/// Transport options of the LSP command-line convention other than `--stdio`, with or without
/// `=<value>`
const other_transports = [_][]const u8{ "--pipe", "--socket", "--port", "--node-ipc" };

/// The command given by `args` (without the program name). Accepts the arguments LSP recommends
/// for clients that start the server: `--stdio`, and `--clientProcessId=<pid>` or
/// `--clientProcessId <pid>`. The process id is only validated: LSP specifies that it is the
/// same as `processId` of `initialize`, which the server watches.
pub fn parse(args: []const []const u8) Command {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "--stdio")) continue;
        const pid_flag = "--clientProcessId";
        if (std.mem.startsWith(u8, arg, pid_flag ++ "=")) {
            if (!validProcessId(arg[pid_flag.len + 1 ..])) return .{ .invalid = .{ .arg = arg, .reason = .invalid_process_id } };
            continue;
        }
        if (std.mem.eql(u8, arg, pid_flag)) {
            i += 1;
            if (i == args.len) return .{ .invalid = .{ .arg = arg, .reason = .missing_process_id } };
            if (!validProcessId(args[i])) return .{ .invalid = .{ .arg = args[i], .reason = .invalid_process_id } };
            continue;
        }
        for (other_transports) |flag| {
            if (std.mem.startsWith(u8, arg, flag) and (arg.len == flag.len or arg[flag.len] == '='))
                return .{ .invalid = .{ .arg = arg, .reason = .unsupported_transport } };
        }
        return .{ .invalid = .{ .arg = arg, .reason = .unknown } };
    }
    return .serve;
}

fn validProcessId(text: []const u8) bool {
    _ = std.fmt.parseInt(u32, text, 10) catch return false;
    return true;
}

const testing = std.testing;

test parse {
    try testing.expectEqual(Command.serve, parse(&.{}));
    try testing.expectEqual(Command.version, parse(&.{"--version"}));
    try testing.expectEqual(Command.help, parse(&.{"--help"}));
    try testing.expectEqualStrings("--bogus", parse(&.{"--bogus"}).invalid.arg);
    try testing.expectEqual(.unsupported_transport, parse(&.{"--pipe=/tmp/p"}).invalid.reason);
    try testing.expectEqual(.unsupported_transport, parse(&.{"--node-ipc"}).invalid.reason);
    try testing.expectEqual(.missing_process_id, parse(&.{"--clientProcessId"}).invalid.reason);
    try testing.expectEqual(.invalid_process_id, parse(&.{"--clientProcessId=abc"}).invalid.reason);
    try testing.expectEqual(.unknown, parse(&.{"--stdiox"}).invalid.reason);
}

test "the stdio transport flags of LSP clients serve LSP" {
    // `--stdio` and `--clientProcessId`, which clients such as vscode-languageclient pass, were
    // rejected as unknown arguments and the server exited
    try testing.expectEqual(Command.serve, parse(&.{"--stdio"}));
    try testing.expectEqual(Command.serve, parse(&.{"--clientProcessId=123"}));
    try testing.expectEqual(Command.serve, parse(&.{ "--clientProcessId", "123" }));
    try testing.expectEqual(Command.serve, parse(&.{ "--stdio", "--clientProcessId=123" }));
    try testing.expectEqual(Command.serve, parse(&.{ "--clientProcessId", "123", "--stdio" }));
}
