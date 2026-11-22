//! What the client supports, from the capabilities it sends in `initialize`.

const std = @import("std");
const types = @import("../lsp/types.zig");

const ClientCaps = @This();

/// The client supports `workspace/configuration`
pull_config: bool = false,
/// The client supports dynamically registering `workspace/didChangeConfiguration` (once
/// registered, the client sends a notification when the configuration changes, and the server
/// pulls the contents)
register_config: bool = false,
/// The client supports dynamically registering `workspace/didChangeWatchedFiles` (watching
/// external changes on disk)
register_watch: bool = false,
/// The client supports deferring `edit` to `codeAction/resolve` (and sends `data` back unchanged):
/// naming fixes look up references only after the user has chosen them
code_action_resolve: bool = false,
/// The client supports `disabled` on code actions (shown as unavailable, with the reason)
code_action_disabled: bool = false,
/// The client supports edits with change annotations in `documentChanges`: renaming a public name
/// requires confirmation from the user
change_annotations: bool = false,
/// The client supports `workspace/applyEdit` (`workspace.applyEdit`): the server can apply the
/// edit that a dependency hash command computes
apply_edit: bool = false,
/// The client supports snippets in completion items (`completionItem.snippetSupport`)
snippet_support: bool = false,
/// The client supports insert and replace ranges in completion items
/// (`completionItem.insertReplaceSupport`)
insert_replace_support: bool = false,
/// The client supports `prepareRename` (`rename.prepareSupport`); otherwise `renameProvider` is
/// a boolean, as `RenameOptions` may only be sent to such clients
prepare_rename: bool = false,
/// The client supports `CodeAction` literals (`codeAction.codeActionLiteralSupport`); otherwise
/// `codeActionProvider` is a boolean and no actions are returned: every action carries an edit
code_action_literals: bool = false,
/// The client supports `DocumentSymbol` trees (`hierarchicalDocumentSymbolSupport`); otherwise
/// the outline is a flat `SymbolInformation[]`
hierarchical_symbols: bool = false,
/// The client lists the symbol kinds it supports in `documentSymbol` and `workspace/symbol`, and
/// so handles any kind; otherwise it supports only `File` to `Array` (see `clientSymbolKind`)
document_symbol_kinds: bool = false,
workspace_symbol_kinds: bool = false,
/// The client lists the completion item kinds it supports, and so handles any kind; otherwise it
/// supports only `Text` to `Reference` (see `clientCompletionKind`)
completion_kinds: bool = false,
/// The client accepts markdown in hover contents, signature documentation, and completion
/// documentation: true unless it lists the formats it supports without markdown
hover_markdown: bool = true,
signature_markdown: bool = true,
/// The client takes parameter labels as offsets into the signature label
/// (`parameterInformation.labelOffsetSupport`); otherwise they are substrings of it, which the
/// client looks up and may find at an earlier parameter with the same text
signature_label_offsets: bool = false,
completion_markdown: bool = true,

pub fn read(caps: *ClientCaps, client: types.ClientCapabilities) void {
    if (client.workspace) |ws| {
        caps.pull_config = ws.configuration orelse false;
        if (ws.didChangeConfiguration) |d| caps.register_config = d.dynamicRegistration orelse false;
        if (ws.didChangeWatchedFiles) |d| caps.register_watch = d.dynamicRegistration orelse false;
        if (ws.workspaceEdit) |we| caps.change_annotations = (we.documentChanges orelse false) and we.changeAnnotationSupport != null;
        caps.apply_edit = ws.applyEdit orelse false;
        if (ws.symbol) |s| if (s.symbolKind) |k| {
            caps.workspace_symbol_kinds = k.valueSet != null;
        };
    }
    if (client.textDocument) |td| if (td.codeAction) |ca| {
        caps.code_action_disabled = ca.disabledSupport orelse false;
        caps.code_action_literals = ca.codeActionLiteralSupport != null;
        if (ca.resolveSupport) |rs| for (rs.properties) |p| {
            if (std.mem.eql(u8, p, "edit")) caps.code_action_resolve = ca.dataSupport orelse false;
        };
    };
    if (client.textDocument) |td| if (td.completion) |c| if (c.completionItem) |ci| {
        caps.snippet_support = ci.snippetSupport orelse false;
        caps.insert_replace_support = ci.insertReplaceSupport orelse false;
    };
    if (client.textDocument) |td| {
        if (td.rename) |rn| caps.prepare_rename = rn.prepareSupport orelse false;
        if (td.documentSymbol) |ds| {
            caps.hierarchical_symbols = ds.hierarchicalDocumentSymbolSupport orelse false;
            if (ds.symbolKind) |k| caps.document_symbol_kinds = k.valueSet != null;
        }
        if (td.completion) |c| {
            if (c.completionItemKind) |k| caps.completion_kinds = k.valueSet != null;
            if (c.completionItem) |ci| if (ci.documentationFormat) |f| {
                caps.completion_markdown = acceptsMarkdown(f);
            };
        }
        if (td.hover) |hv| if (hv.contentFormat) |f| {
            caps.hover_markdown = acceptsMarkdown(f);
        };
        if (td.signatureHelp) |sh| if (sh.signatureInformation) |si| {
            if (si.documentationFormat) |f| caps.signature_markdown = acceptsMarkdown(f);
            if (si.parameterInformation) |pi| caps.signature_label_offsets = pi.labelOffsetSupport orelse false;
        };
    }
}

fn acceptsMarkdown(formats: []const types.MarkupKind) bool {
    return std.mem.findScalar(types.MarkupKind, formats, .markdown) != null;
}
