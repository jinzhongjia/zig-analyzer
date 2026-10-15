//! 注册全部 query 的数据库类型。

const engine = @import("db/engine.zig");
pub const Durability = engine.Durability;
pub const inputs = @import("base/inputs.zig");
pub const syntax = @import("syntax/queries.zig");
pub const live = @import("diagnostics/live.zig");
pub const hir = @import("hir/queries.zig");
pub const ModuleGraph = @import("names/ModuleGraph.zig");
pub const sema = @import("sema/queries.zig");
pub const ide_db = struct {
    pub const FileIndex = @import("ide_db/FileIndex.zig");
};
pub const ide = struct {
    pub const seed = @import("ide/seed.zig");
};

const Vfs = @import("base/Vfs.zig");
const InternPool = @import("sema/InternPool.zig");

/// query 可访问的只读环境（`ctx.db.env`）
pub const Env = struct {
    vfs: *Vfs,
    ip: *InternPool,
};

pub const Db = engine.Engine(*const Env, &.{
    inputs.FileText,
    live.LiveBackend,
    syntax.SourceText,
    syntax.ParseFile,
    syntax.FileItemTree,
    syntax.FileAstIdMap,
    syntax.ItemSummaries,
    live.AstCheck,
    ModuleGraph.Input,
    ModuleGraph.FileImports,
    ModuleGraph.StdRoot,
    hir.ItemBody,
    sema.TargetAbi,
    sema.Infer,
    sema.LocalValue,
    sema.DeclType,
    sema.CallEval,
    sema.ErrorSetOf,
    ide_db.FileIndex.Query,
    ide.seed.Query,
});
