//! 注册全部 query 的数据库类型。

const engine = @import("db/engine.zig");
pub const Durability = engine.Durability;
pub const inputs = @import("base/inputs.zig");
pub const syntax = @import("syntax/queries.zig");
pub const live = @import("diagnostics/live.zig");
pub const hir = @import("hir/queries.zig");

const Vfs = @import("base/Vfs.zig");

pub const Db = engine.Engine(*Vfs, &.{
    inputs.FileText,
    live.LiveBackend,
    syntax.ParseFile,
    syntax.FileItemTree,
    syntax.FileAstIdMap,
    live.AstCheck,
    hir.ItemBody,
});
