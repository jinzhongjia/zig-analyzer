pub const version = "0.0.0-dev";

pub const db = @import("db/engine.zig");
/// 查询统计的文本报告
pub const db_report = @import("db/report.zig");
pub const Server = @import("server/Server.zig");
pub const base = struct {
    pub const Vfs = @import("base/Vfs.zig");
    pub const ProjectModel = @import("base/ProjectModel.zig");
    pub const uri = @import("base/uri.zig");
};
pub const syntax = struct {
    pub const Parse = @import("syntax/Parse.zig");
    pub const ItemTree = @import("syntax/ItemTree.zig");
    pub const queries = @import("syntax/queries.zig");
    pub const ast = @import("syntax/ast.zig");
    pub const FileIndex = @import("syntax/FileIndex.zig");
    pub const ErrorSets = @import("syntax/ErrorSets.zig");
    pub const nesting = @import("syntax/nesting.zig");
    pub const SyntaxKind = @import("syntax/kind.zig").SyntaxKind;
    pub const SyntaxNode = tree.SyntaxNode;
    pub const SyntaxToken = tree.SyntaxToken;
    pub const TextRange = tree.TextRange;
    const tree = @import("syntax/tree.zig");
};
pub const hir = struct {
    pub const Body = @import("hir/Body.zig");
    pub const lower = @import("hir/lower.zig");
};
pub const names = struct {
    pub const ModuleGraph = @import("names/ModuleGraph.zig");
    pub const resolve = @import("names/resolve.zig");
};
pub const database = @import("database.zig");
pub const sema = struct {
    pub const InternPool = @import("sema/InternPool.zig");
    pub const infer = @import("sema/infer.zig");
    pub const value = @import("sema/value.zig");
    pub const eval = @import("sema/eval.zig");
    pub const queries = @import("sema/queries.zig");
    pub const render = @import("sema/render.zig");
};
pub const project = struct {
    pub const ZigEnv = @import("project/ZigEnv.zig");
    pub const bsp = @import("project/bsp.zig");
    pub const error_bundle = @import("project/error_bundle.zig");
    pub const builtin = @import("project/builtin.zig");
    pub const configuration = @import("project/configuration.zig");
    pub const exports = @import("project/exports.zig");
    /// 仅供测试：在临时目录中创建示例项目
    pub const fixture = @import("project/fixture.zig");
};
pub const diagnostics = struct {
    pub const live = @import("diagnostics/live.zig");
    pub const compiler = @import("diagnostics/compiler.zig");
    pub const compile_set = @import("diagnostics/compile_set.zig");
};
pub const ide = struct {
    pub const document_symbol = @import("ide/document_symbol.zig");
    pub const folding = @import("ide/folding.zig");
    pub const selection_range = @import("ide/selection_range.zig");
    pub const semantic_tokens = @import("ide/semantic_tokens.zig");
    pub const format = @import("ide/format.zig");
    pub const definition = @import("ide/definition.zig");
    pub const completion = @import("ide/completion.zig");
    pub const context = @import("ide/context.zig");
    pub const hover = @import("ide/hover.zig");
    pub const signature_help = @import("ide/signature_help.zig");
    pub const inlay_hints = @import("ide/inlay_hints.zig");
    pub const inactive = @import("ide/inactive.zig");
    pub const workspace_symbol = @import("ide/workspace_symbol.zig");
    pub const code_actions = @import("ide/code_actions.zig");
};
pub const ide_db = struct {
    pub const search = @import("ide_db/search.zig");
    pub const seed = @import("ide_db/seed.zig");
};
pub const util = struct {
    pub const offsets = @import("util/offsets.zig");
    pub const log = @import("util/log.zig");
    pub const tracy = @import("util/tracy.zig");
    pub const mem = @import("util/mem.zig");
    pub const panic_context = @import("util/panic_context.zig");
    pub const assert = @import("util/assert.zig");
    /// 仅供测试：posix 写法的路径转为本机路径
    pub const test_path = @import("util/test_path.zig");
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
    std.testing.refAllDecls(db_report);
    std.testing.refAllDecls(util);
    std.testing.refAllDecls(syntax);
    std.testing.refAllDecls(hir);
    std.testing.refAllDecls(names);
    std.testing.refAllDecls(sema);
    std.testing.refAllDecls(diagnostics);
    std.testing.refAllDecls(ide);
    std.testing.refAllDecls(ide_db);
    std.testing.refAllDecls(project);
    std.testing.refAllDecls(lsp);
    _ = @import("lsp/types_test.zig");
}
