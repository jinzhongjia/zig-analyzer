//! 注册全部 query 的数据库类型。

const std = @import("std");

const engine = @import("db/engine.zig");
pub const Durability = engine.Durability;
pub const inputs = @import("base/inputs.zig");
pub const syntax = @import("syntax/queries.zig");
pub const FileIndex = @import("syntax/FileIndex.zig");
pub const ErrorSets = @import("syntax/ErrorSets.zig");
pub const live = @import("diagnostics/live.zig");
pub const hir = @import("hir/queries.zig");
pub const ModuleGraph = @import("names/ModuleGraph.zig");
pub const sema = @import("sema/queries.zig");
pub const ide_db = struct {
    pub const seed = @import("ide_db/seed.zig");
    pub const imports = @import("ide_db/imports.zig");
};
pub const ide = struct {
    pub const naming = @import("ide/naming.zig");
};

const Vfs = @import("base/Vfs.zig");
const InternPool = @import("sema/InternPool.zig");

/// query 可访问的只读环境（`ctx.db.env`）
pub const Env = struct {
    vfs: *Vfs,
    ip: *InternPool,
    /// 配置 `sema.callsite_seeding`：泛型函数体内是否以调用点的实例推导（只在 IDE 层读取，不影响 query 结果）
    callsite_seeding: *const std.atomic.Value(bool) = &always_on,
    /// 在读事务之外预先算好的 live 诊断（见 `live.Prepared`）；null 时总在 query 中计算
    live_prepared: ?*live.Prepared = null,
};

var always_on: std.atomic.Value(bool) = .init(true);

pub const Db = engine.Engine(*const Env, &.{
    inputs.FileText,
    live.LiveBackend,
    syntax.SourceText,
    syntax.ParseFile,
    syntax.FileItemTree,
    syntax.FileAstIdMap,
    syntax.ItemSummaries,
    syntax.ItemNames,
    syntax.ContainerRels,
    live.AstCheck,
    ModuleGraph.Input,
    ModuleGraph.FileImports,
    ModuleGraph.StdRoot,
    hir.ItemBody,
    hir.ParamForms,
    sema.TargetAbi,
    sema.Infer,
    sema.LocalValue,
    sema.DeclType,
    sema.CallEval,
    sema.ComptimeOnly,
    sema.ErrorSetOf,
    sema.InactiveRanges,
    FileIndex.Query,
    ErrorSets.Query,
    ide_db.seed.Query,
    ide_db.seed.Instances,
    ide_db.seed.Candidates,
    ide_db.imports.FileDecls,
    ide_db.imports.ImportSites,
    ide_db.imports.TestOnlyFiles,
    ide_db.imports.FileLinks,
    ide_db.imports.Exports,
    ide_db.imports.BindingNames,
    ide_db.seed.Callers,
    ide_db.seed.AllInstances,
    ide_db.seed.RootCallers,
    ide_db.seed.CallsIn,
    @import("ide_db/search.zig").ProjectImporters,
    ide.naming.Query,
});
