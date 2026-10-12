pub const version = "0.0.0-dev";

pub const db = @import("db/engine.zig");
pub const Server = @import("server/Server.zig");
pub const base = struct {
    pub const Vfs = @import("base/Vfs.zig");
    pub const uri = @import("base/uri.zig");
};
pub const util = struct {
    pub const offsets = @import("util/offsets.zig");
};
pub const lsp = struct {
    pub const types = @import("lsp/types.zig");
    pub const json_ext = @import("lsp/json_ext.zig");
    pub const jsonrpc = @import("lsp/jsonrpc.zig");
    pub const transport = @import("lsp/transport.zig");
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(base);
    std.testing.refAllDecls(util);
    std.testing.refAllDecls(lsp);
    _ = @import("lsp/types_test.zig");
}
