import * as os from "node:os";
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
import * as views from "./views";

/** Scheme of the read-only documents that show the results of the server's custom requests */
const viewScheme = "zig-analyzer";

let client: LanguageClient | undefined;
/** The server command of `client` */
let clientCommand: string | undefined;
let statusItem: vscode.StatusBarItem;
let output: vscode.OutputChannel;
/** The open views by URI, with the document the syntax tree describes */
const openViews = new Map<string, { view: views.View; source?: vscode.Uri }>();
const viewChanged = new vscode.EventEmitter<vscode.Uri>();
/** The decoration of each style of the views */
const viewStyles = new Map<views.Style, vscode.TextEditorDecorationType>();
/** The range of the syntax tree line under the cursor, in the source document */
let rangeDecoration: vscode.TextEditorDecorationType;
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

  registerViews(context);
  context.subscriptions.push(
    vscode.commands.registerCommand("zig-analyzer.menu", showMenu),
    vscode.commands.registerCommand("zig-analyzer.restartServer", () => restart(context)),
    vscode.commands.registerCommand("zig-analyzer.installServer", (options?: installer.InstallOptions) =>
      installCommand(context, options),
    ),
    vscode.commands.registerCommand("zig-analyzer.reloadWorkspace", reloadWorkspace),
    vscode.commands.registerCommand("zig-analyzer.showStatus", () => showView("status", "status")),
    vscode.commands.registerCommand("zig-analyzer.showFileStatus", () => withEditor((doc) => showView("fileStatus", "file-status", doc))),
    vscode.commands.registerCommand("zig-analyzer.showSyntaxTree", () => withEditor((doc) => showView("syntaxTree", "syntax-tree", doc))),
    vscode.commands.registerCommand("zig-analyzer.showModuleGraph", () => showView("moduleGraph", "module-graph")),
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

function withEditor(f: (doc: vscode.Uri) => Promise<void>): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (editor?.document.languageId !== "zig") {
    void vscode.window.showWarningMessage("zig-analyzer: open a Zig or ZON file first.");
    return Promise.resolve();
  }
  return f(editor.document.uri);
}

const viewColors: Record<views.Style, vscode.DecorationRenderOptions> = {
  type: { color: new vscode.ThemeColor("symbolIcon.classForeground") },
  token: { color: new vscode.ThemeColor("symbolIcon.variableForeground") },
  string: { color: new vscode.ThemeColor("debugTokenExpression.string") },
  comment: { color: new vscode.ThemeColor("descriptionForeground") },
  number: { color: new vscode.ThemeColor("debugTokenExpression.number") },
  title: { fontWeight: "bold" },
  label: { color: new vscode.ThemeColor("symbolIcon.propertyForeground") },
  path: { color: new vscode.ThemeColor("textLink.foreground") },
  error: { color: new vscode.ThemeColor("errorForeground") },
};

const viewFormat: views.Format = {
  path(p) {
    const shown = vscode.workspace.asRelativePath(p, false);
    const home = os.homedir();
    return shown === p && p.startsWith(home + path.sep) ? "~" + p.slice(home.length) : shown;
  },
  time(ms) {
    const d = new Date(ms);
    const two = (n: number) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`;
  },
};

/**
 * The views are read-only documents of the `zig-analyzer` scheme, styled with decorations. Go to
 * Definition (Ctrl/Cmd-click) follows a line: it opens a file, goes to the module an import refers
 * to, or goes to the node or token of a syntax tree line in the source document, whose range is
 * highlighted while the cursor is on the line.
 */
function registerViews(context: vscode.ExtensionContext): void {
  for (const [style, options] of Object.entries(viewColors)) viewStyles.set(style as views.Style, vscode.window.createTextEditorDecorationType(options));
  rangeDecoration = vscode.window.createTextEditorDecorationType({ backgroundColor: new vscode.ThemeColor("editor.rangeHighlightBackground") });
  context.subscriptions.push(
    ...viewStyles.values(),
    rangeDecoration,
    vscode.workspace.registerTextDocumentContentProvider(viewScheme, {
      onDidChange: viewChanged.event,
      provideTextDocumentContent: (uri) => openViews.get(uri.toString())?.view.lines.join("\n") ?? "",
    }),
    vscode.languages.registerDefinitionProvider({ scheme: viewScheme }, { provideDefinition: (doc, pos) => viewTarget(doc.uri, pos.line) }),
    vscode.window.onDidChangeVisibleTextEditors(() => {
      for (const e of vscode.window.visibleTextEditors) decorateView(e);
      highlightRange();
    }),
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.document.uri.scheme !== viewScheme) return;
      for (const editor of vscode.window.visibleTextEditors) if (editor.document === e.document) decorateView(editor);
    }),
    vscode.window.onDidChangeTextEditorSelection((e) => {
      if (e.textEditor.document.uri.scheme === viewScheme) highlightRange();
    }),
  );
}

function decorateView(editor: vscode.TextEditor): void {
  const open = openViews.get(editor.document.uri.toString());
  if (editor.document.uri.scheme !== viewScheme || !open) return;
  const ranges = new Map<views.Style, vscode.Range[]>();
  for (const s of open.view.styles) {
    let list = ranges.get(s.style);
    if (!list) ranges.set(s.style, (list = []));
    list.push(new vscode.Range(s.line, s.start, s.line, s.end));
  }
  for (const [style, type] of viewStyles) editor.setDecorations(type, ranges.get(style) ?? []);
}

/** The range of byte offsets `range` in `doc` */
function sourceRange(doc: vscode.TextDocument, range: [number, number]): vscode.Range {
  const index = new views.ByteIndex(doc.getText());
  const start = index.position(range[0]);
  const end = index.position(range[1]);
  return new vscode.Range(start.line, start.character, end.line, end.character);
}

async function viewTarget(uri: vscode.Uri, line: number): Promise<vscode.Location | undefined> {
  const open = openViews.get(uri.toString());
  const t = open?.view.targets.get(line);
  if (!t) return undefined;
  if ("file" in t) return new vscode.Location(vscode.Uri.file(t.file), new vscode.Position(0, 0));
  if ("line" in t) return new vscode.Location(uri, new vscode.Position(t.line, 0));
  if (!open?.source) return undefined;
  const doc = await vscode.workspace.openTextDocument(open.source);
  return new vscode.Location(open.source, sourceRange(doc, t.range).start);
}

/** Highlights, in the visible source editors, the range of the syntax tree line under the cursor */
function highlightRange(): void {
  const ranges = new Map<string, vscode.Range[]>();
  for (const e of vscode.window.visibleTextEditors) {
    const open = openViews.get(e.document.uri.toString());
    const t = open?.view.targets.get(e.selection.active.line);
    if (!open?.source || !t || !("range" in t)) continue;
    const source = vscode.workspace.textDocuments.find((d) => d.uri.toString() === open.source!.toString());
    if (source) ranges.set(source.uri.toString(), [sourceRange(source, t.range)]);
  }
  for (const e of vscode.window.visibleTextEditors) e.setDecorations(rangeDecoration, ranges.get(e.document.uri.toString()) ?? []);
}

async function showView(kind: views.Kind, name: string, source?: vscode.Uri): Promise<void> {
  const c = runningClient();
  if (!c) return;
  const result = await c.sendRequest(`zig-analyzer/${kind}`, source ? { textDocument: { uri: source.toString() } } : undefined);
  const uri = vscode.Uri.from({ scheme: viewScheme, path: "/" + name });
  const view: views.View =
    result === null
      ? { lines: ["No result: the file is not known to zig-analyzer."], styles: [], targets: new Map() }
      : views.render(kind, result, viewFormat);
  openViews.set(uri.toString(), { view, source: kind === "syntaxTree" ? source : undefined });
  viewChanged.fire(uri);
  const doc = await vscode.workspace.openTextDocument(uri);
  const editor = await vscode.window.showTextDocument(doc, { preview: true, viewColumn: vscode.ViewColumn.Beside });
  decorateView(editor);
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
