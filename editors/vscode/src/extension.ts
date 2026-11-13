import * as path from "node:path";
import * as vscode from "vscode";
import {
  LanguageClient,
  type LanguageClientOptions,
  type ServerOptions,
  State,
} from "vscode-languageclient/node";
import * as installer from "./install";
import { configuredServer, section, serverEnv, serverSettings } from "./settings";

/** Scheme of the read-only documents that show the results of the server's custom requests */
const viewScheme = "zig-analyzer";

let client: LanguageClient | undefined;
/** The server command of `client` */
let clientCommand: string | undefined;
let statusItem: vscode.StatusBarItem;
let output: vscode.OutputChannel;
const views = new Map<string, string>();
const viewChanged = new vscode.EventEmitter<vscode.Uri>();
let releaseSource = installer.github;
let installing = false;

/** The API returned to other extensions and tests */
export interface Api {
  client(): LanguageClient | undefined;
  /** The command the server of `client()` runs */
  command(): string | undefined;
  /** The directory **Install Server** installs to */
  installDir(): string;
  /** Installs a release as **Install Server** does; rejects when the install fails */
  install(options: installer.InstallOptions): Promise<installer.Result>;
  /** Where releases are installed from (the tests install fake releases) */
  setReleaseSource(source: installer.ReleaseSource): void;
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
    vscode.commands.registerCommand("zig-analyzer.installServer", (options?: installer.InstallOptions) =>
      installCommand(context, options),
    ),
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
  return {
    client: () => client,
    command: () => clientCommand,
    installDir: () => installDir(context),
    install: (options) => installServer(context, options),
    setReleaseSource: (source) => {
      releaseSource = source;
    },
  };
}

export async function deactivate(): Promise<void> {
  await client?.stop();
  client = undefined;
}

function installDir(context: vscode.ExtensionContext): string {
  return vscode.Uri.joinPath(context.globalStorageUri, "server").fsPath;
}

/**
 * The server command: `zig-analyzer.server.path` when it is set, else the release installed by
 * **Install Server**, else `zig-analyzer` from PATH
 */
function serverCommand(context: vscode.ExtensionContext): { command: string; source: "setting" | "install" | "path" } {
  const configured = configuredServer();
  if (configured !== undefined) return { command: configured, source: "setting" };
  const install = installer.installed(installDir(context));
  if (install !== undefined) return { command: install.exe, source: "install" };
  return { command: "zig-analyzer", source: "path" };
}

async function start(context: vscode.ExtensionContext): Promise<void> {
  const { command, source } = serverCommand(context);
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
  clientCommand = command;
  updateStatus(State.Starting);
  try {
    await c.start();
  } catch (err) {
    updateStatus(State.Stopped);
    const message = err instanceof Error ? err.message : String(err);
    // The server from PATH is missing: offer to install one (unless an install is running)
    const offerInstall = source === "path" && !installing;
    // Not awaited: activation and installs do not wait for the user to close the message
    void vscode.window
      .showErrorMessage(
        `zig-analyzer: failed to start \`${command}\`: ${message}. ` +
          (offerInstall
            ? 'Download a release with "Install Server", or set `zig-analyzer.server.path`.'
            : "Check `zig-analyzer.server.path`."),
        ...(offerInstall ? ["Install Server"] : []),
        "Open Settings",
        "Show Output",
      )
      .then(async (choice) => {
        if (choice === "Install Server") {
          await vscode.commands.executeCommand("zig-analyzer.installServer");
        } else if (choice === "Open Settings") {
          await vscode.commands.executeCommand("workbench.action.openSettings", `${section}.server.path`);
        } else if (choice === "Show Output") {
          output.show(true);
        }
      });
  }
}

async function restart(context: vscode.ExtensionContext): Promise<void> {
  const old = client;
  client = undefined;
  clientCommand = undefined;
  // dispose() stops the client, which rejects when its server failed to start or already exited:
  // start a new one anyway
  await old?.dispose().catch(() => {});
  await start(context);
}

type InstallPick = vscode.QuickPickItem & { options?: installer.InstallOptions };

/** Asks which release to install; undefined when the user cancels */
async function pickRelease(): Promise<installer.InstallOptions | undefined> {
  const modes: InstallPick[] = [
    { label: "ReleaseSafe", detail: "With runtime safety checks (recommended)", options: { optimize: "ReleaseSafe" } },
    { label: "ReleaseFast", detail: "Without runtime safety checks", options: { optimize: "ReleaseFast" } },
  ];
  const picked = await vscode.window.showQuickPick<InstallPick>(
    [
      { label: "Latest release", description: "ReleaseSafe", detail: modes[0].detail, options: { optimize: "ReleaseSafe" } },
      { label: "Latest release", description: "ReleaseFast", detail: modes[1].detail, options: { optimize: "ReleaseFast" } },
      { label: "Another release...", detail: "A release tag, such as v0.1.1" },
    ],
    { placeHolder: "zig-analyzer: the release to download from GitHub" },
  );
  if (picked === undefined || picked.options !== undefined) return picked?.options;
  const version = await vscode.window.showInputBox({
    prompt: "zig-analyzer: the release tag to install",
    placeHolder: "v0.1.1",
    validateInput: (v) => (/^v\d+\.\d+\.\d+[0-9A-Za-z.-]*$/.test(v.trim()) ? undefined : "A release tag, such as v0.1.1"),
  });
  if (version === undefined) return undefined;
  const mode = await vscode.window.showQuickPick(modes, { placeHolder: `zig-analyzer: the build of ${version.trim()}` });
  return mode && { ...mode.options, version: version.trim() };
}

/**
 * **Install Server**: installs the release `options` selects, or one the user picks without
 * them; returns the installed executable, or undefined when nothing was installed
 */
async function installCommand(context: vscode.ExtensionContext, options?: installer.InstallOptions): Promise<string | undefined> {
  const selected = options ?? (await pickRelease());
  if (selected === undefined) return undefined;
  try {
    return (await installServer(context, selected)).exe;
  } catch {
    return undefined;
  }
}

/** Installs a release, then runs it in place of the running server */
async function installServer(context: vscode.ExtensionContext, options: installer.InstallOptions): Promise<installer.Result> {
  if (installing) {
    void vscode.window.showWarningMessage("zig-analyzer: an install is already running.");
    throw new Error("an install is already running");
  }
  installing = true;
  const dir = installDir(context);
  let result: installer.Result;
  try {
    result = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: "zig-analyzer", cancellable: true },
      (progress, token) => {
        const abort = new AbortController();
        token.onCancellationRequested(() => abort.abort());
        return installer.install(dir, options, releaseSource, {
          report: (message, transient) => {
            if (!transient) output.appendLine(`install: ${message}`);
            progress.report({ message });
          },
          signal: abort.signal,
        });
      },
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    output.appendLine(`install failed: ${message}`);
    void vscode.window.showErrorMessage(`zig-analyzer: install failed: ${message}`);
    throw err;
  } finally {
    installing = false;
  }
  let message = `zig-analyzer: ${result.tag} (${result.optimize}) is installed in ${path.dirname(result.exe)}.`;
  output.appendLine(`install: ${result.tag} (${result.optimize}) is installed in ${path.dirname(result.exe)}`);
  if (configuredServer() !== undefined) {
    message += " `zig-analyzer.server.path` is set, so the server it names stays in use.";
  } else if (clientCommand !== result.exe || client?.state !== State.Running) {
    await restart(context);
  }
  // After the restart: on Windows the running executable cannot be removed
  await installer.removeOthers(dir, result.release);
  void vscode.window.showInformationMessage(message);
  return result;
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
    { label: "$(cloud-download) Install Server", detail: "Download a release from GitHub", command: "zig-analyzer.installServer" },
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
