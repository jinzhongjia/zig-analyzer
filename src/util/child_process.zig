//! Starting the child processes of the server (zig and the processes that keep it in check).

const std = @import("std");
const Io = std.Io;
const process = std.process;

/// `std.process.spawn` for every child process the server starts. On Windows the child gets no
/// console window: an editor usually starts the server without a console, and a console program
/// started from such a process opens a console window of its own unless `CREATE_NO_WINDOW` is
/// set. The children's standard streams are pipes or null, so that window would only show an
/// empty console. `std.process.run` already sets the flag by default; `std.process.spawn` does not.
pub fn spawn(io: Io, options: process.SpawnOptions) process.SpawnError!process.Child {
    return process.spawn(io, withoutWindow(options));
}

fn withoutWindow(options: process.SpawnOptions) process.SpawnOptions {
    var o = options;
    o.create_no_window = true;
    return o;
}

test "children are spawned without a console window" {
    // `std.process.spawn` opens a console window for each child of a console-less server unless
    // asked not to
    try std.testing.expect(!(process.SpawnOptions{ .argv = &.{"zig"} }).create_no_window);
    try std.testing.expect(withoutWindow(.{ .argv = &.{"zig"} }).create_no_window);
    try std.testing.expect(withoutWindow(.{ .argv = &.{"zig"}, .create_no_window = false }).create_no_window);
}
