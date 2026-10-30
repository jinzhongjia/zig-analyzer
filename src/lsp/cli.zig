//! Command-line arguments of the server executable.

const std = @import("std");

pub const usage =
    \\Usage: zig-analyzer [options]
    \\
    \\Zig language server (LSP) over stdio.
    \\
    \\Options:
    \\  --version   print version
    \\  --help      print this help
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
    reason: enum { unknown },

    pub fn format(i: Invalid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (i.reason) {
            .unknown => try w.print("unknown argument: {s}", .{i.arg}),
        }
    }
};

/// The command given by `args` (without the program name)
pub fn parse(args: []const []const u8) Command {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--help")) return .help;
        return .{ .invalid = .{ .arg = arg, .reason = .unknown } };
    }
    return .serve;
}

const testing = std.testing;

test parse {
    try testing.expectEqual(Command.serve, parse(&.{}));
    try testing.expectEqual(Command.version, parse(&.{"--version"}));
    try testing.expectEqual(Command.help, parse(&.{"--help"}));
    try testing.expectEqualStrings("--bogus", parse(&.{"--bogus"}).invalid.arg);
}
