import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import type { Api } from "../src/extension";

const results: string[] = [];
let failures = 0;

function check(cond: unknown, what: string): void {
  results.push(`${cond ? "ok  " : "FAIL"} ${what}`);
  if (!cond) failures++;
}

async function sleep(ms: number): Promise<void> {
  await new Promise((r) => setTimeout(r, ms));
}

/** Retries `f` until `ok` holds for its result (requests canceled by edits return nothing) */
async function poll<T>(f: () => Thenable<T>, ok: (v: T) => unknown, ms = 30_000): Promise<T> {
  const deadline = Date.now() + ms;
  for (;;) {
    let v: T | undefined;
    try {
      v = await f();
    } catch {
      v = undefined;
    }
    if (v !== undefined && ok(v)) return v;
    if (Date.now() > deadline) return v as T;
    await sleep(200);
  }
}

function hoverText(hovers: vscode.Hover[] | undefined): string {
  return (hovers ?? []).flatMap((h) => h.contents.map((c) => (typeof c === "string" ? c : c.value))).join("\n");
}

function hintLabel(h: vscode.InlayHint): string {
  return typeof h.label === "string" ? h.label : h.label.map((p) => p.value).join("");
}

export async function run(): Promise<void> {
  const root = vscode.workspace.workspaceFolders![0].uri;
  const uri = (rel: string) => vscode.Uri.joinPath(root, rel);
  /** The position of `needle` in a project file, `delta` characters after its start */
  const pos = (rel: string, needle: string, delta = 0): vscode.Position => {
    const lines = fs.readFileSync(uri(rel).fsPath, "utf8").split("\n");
    const line = lines.findIndex((l) => l.includes(needle));
    if (line < 0) throw new Error(`not found: ${needle}`);
    return new vscode.Position(line, lines[line].indexOf(needle) + delta);
  };

  const main = uri("src/main.zig");
  const doc = await vscode.workspace.openTextDocument(main);
  await vscode.window.showTextDocument(doc);
  check(doc.languageId === "zig", "language is zig");

  const api = await vscode.extensions.getExtension<Api>("jinzhongjia.zig-analyzer")!.activate();
  const client = await poll(async () => api.client(), (c) => c?.isRunning());
  check(client?.isRunning(), "the server is running");
  await client!.sendRequest("zig-analyzer/waitIdle");

  const status = await client!.sendRequest<{ projects: { root: string }[]; modules: string[] } | null>(
    "zig-analyzer/fileStatus",
    { textDocument: { uri: main.toString() } },
  );
  check(
    status?.projects.length === 1 && status.projects[0].root === root.fsPath && status.modules.length > 0,
    "the file belongs to the build.zig project",
  );

  const call = pos("src/main.zig", "shapes.area(square)", 7);
  const hover = hoverText(await poll(() => vscode.commands.executeCommand<vscode.Hover[]>("vscode.executeHoverProvider", main, call), (h) => h.length > 0));
  check(hover.includes("fn area(s: Square) u32") && hover.includes("The area of a square."), "hover shows the signature and the doc comment");

  const defs = await poll(
    () => vscode.commands.executeCommand<(vscode.Location | vscode.LocationLink)[]>("vscode.executeDefinitionProvider", main, call),
    (d) => d.length > 0,
  );
  const def = defs[0] as vscode.Location & vscode.LocationLink;
  check(
    (def?.targetUri ?? def?.uri)?.toString() === uri("src/shapes.zig").toString() &&
      (def.targetSelectionRange ?? def.targetRange ?? def.range).start.line === pos("src/shapes.zig", "pub fn area").line,
    "definition in the other file",
  );

  const refs = await poll(() => vscode.commands.executeCommand<vscode.Location[]>("vscode.executeReferenceProvider", main, call), (r) => r.length > 0);
  check(refs.length === 3, `references: declaration and two calls (${refs.length})`);

  const prepared = await vscode.commands.executeCommand<unknown>("vscode.prepareRename", main, call);
  check(prepared, "prepareRename");
  const edit = await vscode.commands.executeCommand<vscode.WorkspaceEdit>("vscode.executeDocumentRenameProvider", main, call, "surface");
  const entries = edit?.entries() ?? [];
  const edits = entries.reduce((n, [, e]) => n + e.length, 0);
  check(entries.length === 2 && edits === 3, `rename: 3 edits in 2 files (${edits} in ${entries.length})`);

  const completion = await poll(
    () => vscode.commands.executeCommand<vscode.CompletionList>("vscode.executeCompletionItemProvider", main, call),
    (c) => c.items.length > 0,
  );
  const labels = new Set(completion.items.map((i) => (typeof i.label === "string" ? i.label : i.label.label)));
  check(labels.has("area") && labels.has("Square"), "completion of the members of shapes");

  const sig = await poll(
    () => vscode.commands.executeCommand<vscode.SignatureHelp>("vscode.executeSignatureHelpProvider", main, pos("src/main.zig", "shapes.area(square)", 12)),
    (s) => s?.signatures.length > 0,
  );
  check(sig?.signatures[0]?.label.includes("area(s: Square)"), "signature help");

  const allLines = new vscode.Range(0, 0, doc.lineCount, 0);
  const hints = await poll(() => vscode.commands.executeCommand<vscode.InlayHint[]>("vscode.executeInlayHintProvider", main, allLines), (h) => h.length > 0);
  const hintText = hints.map(hintLabel).join(" ");
  check(hintText.includes(": u32"), `type hint (${hintText})`);
  // Single-argument calls show no parameter names by default: this one comes from the settings
  check(hintText.includes("s:"), "parameter hint enabled by the settings");

  // A settings change reaches the server: the parameter name disappears again
  await vscode.workspace.getConfiguration("zig-analyzer").update("inlay_hints.exclude_single_argument", true, vscode.ConfigurationTarget.Workspace);
  const after = await poll(
    () => vscode.commands.executeCommand<vscode.InlayHint[]>("vscode.executeInlayHintProvider", main, allLines),
    (h) => !h.map(hintLabel).some((l) => l === "s:"),
  );
  check(!after.map(hintLabel).some((l) => l === "s:"), "a settings change reaches the server");

  const tokens = await poll(() => vscode.commands.executeCommand<vscode.SemanticTokens>("vscode.provideDocumentSemanticTokens", main), (t) => t?.data.length > 0);
  check(tokens?.data.length > 0 && tokens.data.length % 5 === 0, "semantic tokens");

  const shapes = uri("src/shapes.zig");
  await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(shapes));
  const symbols = await poll(
    () => vscode.commands.executeCommand<vscode.DocumentSymbol[]>("vscode.executeDocumentSymbolProvider", shapes),
    (s) => s?.length > 0,
  );
  const square = symbols.find((s) => s.name === "Square");
  check(square?.children[0]?.name === "side" && symbols.some((s) => s.name === "area"), "document symbols with children");

  const folds = await poll(() => vscode.commands.executeCommand<vscode.FoldingRange[]>("vscode.executeFoldingRangeProvider", shapes), (f) => f?.length > 0);
  check(folds?.length > 0, "folding ranges");

  const ws = await poll(
    () => vscode.commands.executeCommand<vscode.SymbolInformation[]>("vscode.executeWorkspaceSymbolProvider", "Square"),
    (s) => s.length > 0,
  );
  check(ws.some((s) => s.name === "Square" && s.location.uri.toString() === shapes.toString()), "workspace symbol");

  const lint = uri("src/lint.zig");
  await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(lint));
  const diags = await poll(async () => vscode.languages.getDiagnostics(lint), (d) => d.length > 0);
  check(diags[0]?.message.includes("unused local constant"), "live diagnostic");
  if (diags[0]) {
    const actions = await poll(
      () => vscode.commands.executeCommand<vscode.CodeAction[]>("vscode.executeCodeActionProvider", lint, diags[0].range, vscode.CodeActionKind.QuickFix.value),
      (a) => a.length > 0,
    );
    check(actions.length > 0, `quick fix for the unused constant (${actions.length})`);
  }
  const fmt = await vscode.commands.executeCommand<vscode.TextEdit[]>("vscode.executeFormatDocumentProvider", lint, { tabSize: 4, insertSpaces: true });
  check(fmt?.length > 0, "formatting");

  const zon = uri("build.zig.zon");
  const zonDoc = await vscode.workspace.openTextDocument(zon);
  await vscode.window.showTextDocument(zonDoc);
  check(zonDoc.languageId === "zig", "build.zig.zon is handled");
  const zonSymbols = await poll(
    () => vscode.commands.executeCommand<vscode.DocumentSymbol[]>("vscode.executeDocumentSymbolProvider", zon),
    (s) => s?.length > 0,
  );
  check(zonSymbols?.some((s) => s.name === "name" || s.name === ".name"), "ZON outline");
  const zonHover = await poll(() => vscode.commands.executeCommand<vscode.Hover[]>("vscode.executeHoverProvider", zon, pos("build.zig.zon", ".paths", 2)), (h) => h.length > 0);
  check(zonHover.length > 0, "ZON hover on a manifest field");

  await vscode.window.showTextDocument(doc);
  const view = async (command: string, name: string): Promise<string> => {
    await vscode.commands.executeCommand(command);
    const d = await poll(
      async () => vscode.window.visibleTextEditors.find((e) => e.document.uri.scheme === "zig-analyzer" && path.basename(e.document.uri.path) === name)?.document,
      (x) => x !== undefined,
    );
    return d?.getText() ?? "";
  };
  const tree = await view("zig-analyzer.showSyntaxTree", "syntax-tree");
  check(/^source_file@0\.\.\d+$/m.test(tree), "Show Syntax Tree");
  // Go to Definition on the `std` identifier of `const std = ...` goes to it in the source
  const treeUri = vscode.Uri.from({ scheme: "zig-analyzer", path: "/syntax-tree" });
  const stdLine = tree.split("\n").findIndex((l) => /^\s*identifier@\d+\.\.\d+ "std"$/.test(l));
  const treeDefs = await vscode.commands.executeCommand<vscode.Location[]>("vscode.executeDefinitionProvider", treeUri, new vscode.Position(stdLine, 4));
  check(treeDefs?.[0]?.uri.toString() === main.toString() && treeDefs[0].range.start.isEqual(pos("src/main.zig", "std")),
    "Show Syntax Tree: a line goes to the source");
  await vscode.window.showTextDocument(doc);
  const graph = await view("zig-analyzer.showModuleGraph", "module-graph");
  check(graph.split("\n").some((l) => /^\[\d+\] src\/main\.zig /.test(l)), "Show Module Graph lists the project root module");
  check(/^Revision +\d+$/m.test(await view("zig-analyzer.showStatus", "status")), "Show Server Status");
  await vscode.window.showTextDocument(doc);
  check(/^Projects +\S/m.test(await view("zig-analyzer.showFileStatus", "file-status")), "Show File Status");

  await vscode.commands.executeCommand("zig-analyzer.reloadWorkspace");
  await client!.sendRequest("zig-analyzer/waitIdle");
  const reloaded = await client!.sendRequest<{ projects: unknown[] } | null>("zig-analyzer/fileStatus", { textDocument: { uri: main.toString() } });
  check(reloaded?.projects.length === 1, "Reload Workspace reloads the project");

  await vscode.commands.executeCommand("zig-analyzer.restartServer");
  const restarted = await poll(async () => api.client(), (c) => c !== undefined && c !== client && c.isRunning());
  check(restarted !== client && restarted?.isRunning(), "Restart Server");
  await restarted?.sendRequest("zig-analyzer/waitIdle");

  console.log(results.join("\n"));
  if (failures > 0) throw new Error(`${failures} checks failed`);
  console.log("all checks passed");
}
