import * as assert from "node:assert/strict";
import * as path from "node:path";
import * as vscode from "vscode";
import type { Api } from "../src/extension";

async function until<T>(what: string, f: () => Promise<T | undefined>, ms = 60_000): Promise<T> {
  const deadline = Date.now() + ms;
  for (;;) {
    const v = await f();
    if (v !== undefined) return v;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 200));
  }
}

export async function run(): Promise<void> {
  const folder = vscode.workspace.workspaceFolders![0].uri;
  const uri = vscode.Uri.joinPath(folder, "main.zig");
  const doc = await vscode.workspace.openTextDocument(uri);
  await vscode.window.showTextDocument(doc);
  assert.equal(doc.languageId, "zig");

  const extension = vscode.extensions.getExtension<Api>("jinzhongjia.zig-analyzer")!;
  const api = await extension.activate();
  const client = await until("the client", async () => api.client());
  await client.sendRequest("zig-analyzer/waitIdle");

  // Hover on the call of `add`
  const call = new vscode.Position(7, 16);
  const hovers = await vscode.commands.executeCommand<vscode.Hover[]>("vscode.executeHoverProvider", uri, call);
  const hoverText = hovers.flatMap((h) => h.contents.map((c) => (typeof c === "string" ? c : c.value))).join("\n");
  assert.match(hoverText, /fn add\(a: u32, b: u32\) u32/);

  // Goto definition
  const defs = await vscode.commands.executeCommand<(vscode.Location | vscode.LocationLink)[]>(
    "vscode.executeDefinitionProvider",
    uri,
    call,
  );
  const target = defs[0] as vscode.Location & vscode.LocationLink;
  assert.equal((target.targetRange ?? target.range).start.line, 2);

  // Formatting (as `zig fmt`)
  const edits = await vscode.commands.executeCommand<vscode.TextEdit[]>("vscode.executeFormatDocumentProvider", uri, {
    tabSize: 4,
    insertSpaces: true,
  });
  assert.ok(edits.length > 0, "expected formatting edits");

  // Inlay hints follow the settings: type hints on, parameter names off in this workspace
  const hints = await vscode.commands.executeCommand<vscode.InlayHint[]>(
    "vscode.executeInlayHintProvider",
    uri,
    new vscode.Range(0, 0, doc.lineCount, 0),
  );
  const labels = hints.map((h) => (typeof h.label === "string" ? h.label : h.label.map((p) => p.value).join("")));
  assert.ok(labels.some((l) => l.includes("u32")), `expected a type hint, got ${JSON.stringify(labels)}`);
  assert.ok(!labels.some((l) => l.startsWith("a:")), `expected no parameter hints, got ${JSON.stringify(labels)}`);

  // Changing a setting reaches the server: parameter names appear
  await vscode.workspace.getConfiguration("zig-analyzer").update("inlay_hints.parameters", true, vscode.ConfigurationTarget.Workspace);
  await until("parameter hints", async () => {
    const hs = await vscode.commands.executeCommand<vscode.InlayHint[]>(
      "vscode.executeInlayHintProvider",
      uri,
      new vscode.Range(0, 0, doc.lineCount, 0),
    );
    return hs.some((h) => (typeof h.label === "string" ? h.label : h.label.map((p) => p.value).join("")).startsWith("a:"))
      ? true
      : undefined;
  });

  // Semantic tokens
  const tokens = await vscode.commands.executeCommand<vscode.SemanticTokens>(
    "vscode.provideDocumentSemanticTokens",
    uri,
  );
  assert.ok(tokens.data.length > 0, "expected semantic tokens");

  // Custom requests through the commands
  await vscode.commands.executeCommand("zig-analyzer.showSyntaxTree");
  const view = await until("the syntax tree view", async () =>
    vscode.window.visibleTextEditors.find((e) => e.document.uri.scheme === "zig-analyzer")?.document,
  );
  assert.match(view.getText(), /^source_file@0\.\.\d+$/m);
  assert.equal(path.basename(view.uri.path), "syntax-tree.txt");

  await vscode.commands.executeCommand("zig-analyzer.reloadWorkspace");
  await vscode.commands.executeCommand("zig-analyzer.restartServer");
  const restarted = await until("the restarted client", async () => {
    const c = api.client();
    return c && c !== client && c.isRunning() ? c : undefined;
  });
  await restarted.sendRequest("zig-analyzer/waitIdle");
}
