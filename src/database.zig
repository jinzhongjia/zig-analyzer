//! Database type that registers all queries.

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
    pub const completion = @import("ide/completion.zig");
    pub const format = @import("ide/format.zig");
};

const Vfs = @import("base/Vfs.zig");
const InternPool = @import("sema/InternPool.zig");

/// Read-only environment accessible to queries (`ctx.db.env`)
pub const Env = struct {
    vfs: *Vfs,
    ip: *InternPool,
    /// Config option `sema.callsite_seeding`: whether generic function bodies are inferred with the
    /// instances from call sites (read only in the IDE layer; does not affect query results)
    callsite_seeding: *const std.atomic.Value(bool) = &always_on,
    /// Live diagnostics precomputed outside the read transaction (see `live.Prepared`); when null,
    /// they are always computed in the query
    live_prepared: ?*live.Prepared = null,
    /// Environment variables of the `zig ast-check` child processes of live diagnostics: those of
    /// the effective zig environment (see `ZigEnv.childEnviron`), so that they run with the zig path
    /// overrides as every other zig process does; null inherits those of the current process. Does
    /// not affect query results: `zig ast-check` reads only the text passed to it.
    zig_environ: *const std.atomic.Value(?*const std.process.Environ.Map) = &no_environ,
};

var always_on: std.atomic.Value(bool) = .init(true);
var no_environ: std.atomic.Value(?*const std.process.Environ.Map) = .init(null);

pub const Db = engine.Engine(*const Env, &.{
    inputs.FileText,
    inputs.WorkspaceFiles,
    live.LiveBackend,
    syntax.SyntaxDialect,
    ide.format.ZigFmtRenderer,
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
    ModuleGraph.FileContext,
    ModuleGraph.ContextImports,
    hir.ItemBody,
    hir.ParamForms,
    sema.TargetAbi,
    sema.ContextTarget,
    sema.Infer,
    sema.LocalValue,
    sema.LocalEval,
    sema.CapturedVar,
    sema.SignatureInst,
    sema.DeclType,
    sema.CallEval,
    sema.ComptimeOnly,
    sema.ErrorSetOf,
    sema.InactiveRanges,
    sema.ZonValue,
    sema.ZonImports,
    sema.ZonResultType,
    FileIndex.Query,
    ErrorSets.Query,
    ide_db.seed.Query,
    ide_db.seed.Instances,
    ide_db.seed.Candidates,
    ide_db.seed.NameIndex,
    ide_db.seed.NameFiles,
    ide_db.imports.DeclNamespace,
    ide_db.imports.DeclTarget,
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
    ide.completion.CallParams,
});
