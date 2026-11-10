import * as vscode from "vscode";
import {
  LanguageClient,
  type LanguageClientOptions,
  type ServerOptions,
  State,
} from "vscode-languageclient/node";
import { section, serverCommand, serverEnv, serverSettings } from "./settings";

/** Scheme of the read-only documents that show the results of the server's custom requests */
const viewScheme = "zig-analyzer";

let client: LanguageClient | undefined;
let statusItem: vscode.StatusBarItem;
let output: vscode.OutputChannel;
const views = new Map<string, string>();
const viewChanged = new vscode.EventEmitter<vscode.Uri>();

/** The API returned to other extensions and tests */
export interface Api {
  client(): LanguageClient | undefined;
}

export async function activate(context: vscode.ExtensionContext): Promise<Api> {
  output = vscode.window.createOutputChannel("zig-analyzer");
  statusItem = vscode.window.createStatusBarItem("zig-analyzer.status", vscode.StatusBarAlignment.Left);
  statusItem.name = "zig-analyzer";
  statusItem.command = "zig-analyzer.menu";
  context.subscriptions.push(output, statusItem, viewChanged);

  context.subscriptions.push(
    vscode.workspace.registerTextDocumentContentProvider(viewScheme, {
      onDidChange: viewChanged.event,
      provideTextDocumentContent: (uri) => views.get(uri.toString()) ?? "",
    }),
    vscode.commands.registerCommand("zig-analyzer.menu", showMenu),
    vscode.commands.registerCommand("zig-analyzer.restartServer", () => restart(context)),
    vscode.commands.registerCommand("zig-analyzer.reloadWorkspace", reloadWorkspace),
    vscode.commands.registerCommand("zig-analyzer.showStatus", () =>
      showView("status.json", "zig-analyzer/status", undefined, json),
    ),
    vscode.commands.registerCommand("zig-analyzer.showFileStatus", () =>
      withEditor((uri) => showView("file-status.json", "zig-analyzer/fileStatus", { textDocument: { uri } }, json)),
    ),
    vscode.commands.registerCommand("zig-analyzer.showSyntaxTree", () =>
      withEditor((uri) => showView("syntax-tree.txt", "zig-analyzer/syntaxTree", { textDocument: { uri } }, text)),
    ),
    vscode.commands.registerCommand("zig-analyzer.showModuleGraph", () =>
      showView("module-graph.json", "zig-analyzer/moduleGraph", undefined, json),
    ),
    vscode.commands.registerCommand("zig-analyzer.showOutput", () => output.show(true)),
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (!e.affectsConfiguration(`${section}.server`)) return;
      const choice = await vscode.window.showInformationMessage(
        "zig-analyzer: the server settings changed. Restart the server to apply them?",
        "Restart",
      );
      if (choice === "Restart") await restart(context);
    }),
    { dispose: () => void client?.stop() },
  );

  checkZls(context);
  await start(context);
  return { client: () => client };
}

export async function deactivate(): Promise<void> {
  await client?.stop();
  client = undefined;
}

async function start(context: vscode.ExtensionContext): Promise<void> {
  const command = serverCommand();
  const serverOptions: ServerOptions = { command, options: { env: serverEnv() } };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "zig" },
      { scheme: "untitled", language: "zig" },
    ],
    outputChannel: output,
    initializationOptions: () => serverSettings(context.extension),
    middleware: {
      workspace: {
        // The server pulls the `zig-analyzer` section: answer with the settings in the shape it
        // expects, without the extension's own settings
        configuration: async (params, token, next) => {
          const result = await next(params, token);
          if (!Array.isArray(result)) return result;
          return params.items.map((item, i) =>
            item.section === section ? serverSettings(context.extension) : result[i],
          );
        },
      },
    },
  };
  const c = new LanguageClient(section, "zig-analyzer", serverOptions, clientOptions);
  c.onDidChangeState((e) => updateStatus(e.newState));
  client = c;
  updateStatus(State.Starting);
  try {
    await c.start();
  } catch (err) {
    updateStatus(State.Stopped);
    const message = err instanceof Error ? err.message : String(err);
    const choice = await vscode.window.showErrorMessage(
      `zig-analyzer: failed to start \`${command}\`: ${message}. Install zig-analyzer, or set \`zig-analyzer.server.path\`.`,
      "Open Settings",
      "Show Output",
    );
    if (choice === "Open Settings") {
      await vscode.commands.executeCommand("workbench.action.openSettings", `${section}.server.path`);
    } else if (choice === "Show Output") {
      output.show(true);
    }
  }
}

async function restart(context: vscode.ExtensionContext): Promise<void> {
  const old = client;
  client = undefined;
  if (old) {
    try {
      await old.stop();
    } catch {
      // A server that already exited cannot be stopped; start a new one anyway
    }
    await old.dispose();
  }
  await start(context);
}

function updateStatus(state: State): void {
  switch (state) {
    case State.Starting:
      statusItem.text = "$(sync~spin) zig-analyzer";
      statusItem.tooltip = "zig-analyzer is starting";
      statusItem.backgroundColor = undefined;
      break;
    case State.Running:
      statusItem.text = "$(check) zig-analyzer";
      statusItem.tooltip = "zig-analyzer is running";
      statusItem.backgroundColor = undefined;
      break;
    case State.Stopped:
      statusItem.text = "$(error) zig-analyzer";
      statusItem.tooltip = "zig-analyzer is not running";
      statusItem.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
      break;
  }
  statusItem.show();
}

async function showMenu(): Promise<void> {
  const items: (vscode.QuickPickItem & { command: string })[] = [
    { label: "$(debug-restart) Restart Server", command: "zig-analyzer.restartServer" },
    { label: "$(refresh) Reload Workspace", detail: "Rerun build.zig", command: "zig-analyzer.reloadWorkspace" },
    { label: "$(info) Show Server Status", command: "zig-analyzer.showStatus" },
    { label: "$(file) Show File Status", command: "zig-analyzer.showFileStatus" },
    { label: "$(list-tree) Show Syntax Tree", command: "zig-analyzer.showSyntaxTree" },
    { label: "$(type-hierarchy) Show Module Graph", command: "zig-analyzer.showModuleGraph" },
    { label: "$(output) Show Output", command: "zig-analyzer.showOutput" },
  ];
  const picked = await vscode.window.showQuickPick(items, { placeHolder: "zig-analyzer" });
  if (picked) await vscode.commands.executeCommand(picked.command);
}

function runningClient(): LanguageClient | undefined {
  if (client?.state === State.Running) return client;
  void vscode.window.showWarningMessage("zig-analyzer is not running.");
  return undefined;
}

async function reloadWorkspace(): Promise<void> {
  await runningClient()?.sendRequest("zig-analyzer/reloadWorkspace");
}

function withEditor(f: (uri: string) => Promise<void>): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (editor?.document.languageId !== "zig") {
    void vscode.window.showWarningMessage("zig-analyzer: open a Zig or ZON file first.");
    return Promise.resolve();
  }
  return f(editor.document.uri.toString());
}

const json = (r: unknown) => JSON.stringify(r, null, 2);
const text = (r: unknown) => (typeof r === "string" ? r : json(r));

async function showView(name: string, method: string, params: unknown, render: (r: unknown) => string): Promise<void> {
  const c = runningClient();
  if (!c) return;
  const result = await c.sendRequest(method, params);
  const uri = vscode.Uri.from({ scheme: viewScheme, path: "/" + name });
  views.set(uri.toString(), result === null ? "No result: the file is not known to zig-analyzer." : render(result));
  viewChanged.fire(uri);
  const doc = await vscode.workspace.openTextDocument(uri);
  await vscode.window.showTextDocument(doc, { preview: true, viewColumn: vscode.ViewColumn.Beside });
}

/**
 * The Zig extension (`ziglang.vscode-zig`) starts ZLS for the same files: offer to turn it off in
 * this workspace, so that the two servers do not answer the same requests twice.
 */
function checkZls(context: vscode.ExtensionContext): void {
  if (!vscode.extensions.getExtension("ziglang.vscode-zig")) return;
  const zls = vscode.workspace.getConfiguration("zig.zls");
  if (zls.get<string>("enabled") === "off") return;
  if (context.globalState.get<boolean>("zlsPromptDismissed")) return;
  void vscode.window
    .showInformationMessage(
      "The Zig extension also starts ZLS for Zig files. Turn ZLS off to use only zig-analyzer?",
      "Turn Off ZLS",
      "Don't Ask Again",
    )
    .then(async (choice) => {
      if (choice === "Turn Off ZLS") {
        await zls.update("enabled", "off", vscode.ConfigurationTarget.Global);
        const reload = await vscode.window.showInformationMessage("Reload the window to stop ZLS?", "Reload");
        if (reload === "Reload") await vscode.commands.executeCommand("workbench.action.reloadWindow");
      } else if (choice === "Don't Ask Again") {
        await context.globalState.update("zlsPromptDismissed", true);
      }
    });
}
