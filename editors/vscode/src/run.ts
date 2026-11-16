// Running and debugging: the Run and Debug commands and code lenses of `pub fn main`, and the
// tests of the open Zig files in the Testing view. Everything here runs the `zig` of
// `zig-analyzer.zig.path`, without the server.
import * as cp from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";
import * as entries from "./entries";
import { section, zigPath } from "./settings";

let output: vscode.OutputChannel;
let controller: vscode.TestController;

export function register(context: vscode.ExtensionContext, channel: vscode.OutputChannel): void {
  output = channel;
  controller = vscode.tests.createTestController("zig-analyzer", "Zig Tests");
  controller.createRunProfile("Run", vscode.TestRunProfileKind.Run, (request, token) => runTests(request, token, false), true);
  controller.createRunProfile("Debug", vscode.TestRunProfileKind.Debug, (request, token) => runTests(request, token, true), false);
  for (const doc of vscode.workspace.textDocuments) updateTests(doc);
  context.subscriptions.push(
    controller,
    vscode.workspace.onDidOpenTextDocument(updateTests),
    vscode.workspace.onDidChangeTextDocument((e) => updateTests(e.document)),
    vscode.commands.registerCommand("zig-analyzer.run", run),
    vscode.commands.registerCommand("zig-analyzer.debug", debug),
    vscode.languages.registerCodeLensProvider({ scheme: "file", language: "zig" }, { provideCodeLenses }),
  );
}

function provideCodeLenses(doc: vscode.TextDocument): vscode.CodeLens[] {
  return entries.mains(doc.getText()).flatMap((main) => {
    const range = doc.lineAt(doc.positionAt(main.offset)).range;
    return [
      new vscode.CodeLens(range, { title: "Run", command: "zig-analyzer.run", arguments: [doc.uri.fsPath] }),
      new vscode.CodeLens(range, { title: "Debug", command: "zig-analyzer.debug", arguments: [doc.uri.fsPath] }),
    ];
  });
}

/** The nearest directory above `file` that has a `build.zig` */
function buildRoot(file: string): string | undefined {
  for (let dir = path.dirname(file); ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, "build.zig"))) return dir;
    if (path.dirname(dir) === dir) return undefined;
  }
}

/** `file`, else the Zig file of the active editor */
function target(file: unknown): string | undefined {
  if (typeof file === "string") return file;
  const doc = vscode.window.activeTextEditor?.document;
  if (doc?.languageId === "zig" && doc.uri.scheme === "file") return doc.uri.fsPath;
  void vscode.window.showInformationMessage("zig-analyzer: open a Zig file first.");
  return undefined;
}

/** `zig build run` in the project of the file, `zig run` of a file outside any project */
async function run(arg?: unknown): Promise<void> {
  const file = target(arg);
  if (file === undefined) return;
  const root = buildRoot(file);
  const task = new vscode.Task(
    { type: "process" },
    vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file)) ?? vscode.TaskScope.Global,
    root ? "zig build run" : `zig run ${path.basename(file)}`,
    "zig-analyzer",
    new vscode.ProcessExecution(zigPath(), root ? ["build", "run"] : ["run", file], { cwd: root ?? path.dirname(file) }),
    "$zig",
  );
  await vscode.tasks.executeTask(task);
}

/** Runs zig to its end: its exit code (undefined when it could not run) and what it wrote to stderr */
function zig(args: string[], cwd: string, token?: vscode.CancellationToken): Promise<{ code: number | undefined; stderr: string }> {
  return new Promise((resolve) => {
    const child = cp.execFile(zigPath(), args, { cwd, maxBuffer: 64 * 1024 * 1024 }, (err, _stdout, stderr) => {
      cancel?.dispose();
      if (err && typeof err.code !== "number") resolve({ code: undefined, stderr: stderr || err.message });
      else resolve({ code: err ? (err.code as number) : 0, stderr });
    });
    const cancel = token?.onCancellationRequested(() => child.kill());
  });
}

/** Where the executable `name` to debug is built */
function debugBinary(name: string): string {
  const dir = path.join(os.tmpdir(), "zig-analyzer-debug");
  fs.mkdirSync(dir, { recursive: true });
  return path.join(dir, process.platform === "win32" ? `${name}.exe` : name);
}

async function startDebugging(program: string, cwd: string): Promise<void> {
  const type = vscode.workspace.getConfiguration(section).get<string>("debug.adapter", "lldb");
  await vscode.debug.startDebugging(undefined, { type, name: "Debug Zig", request: "launch", program, cwd });
}

function buildFailed(stderr: string): void {
  output.appendLine(stderr);
  void vscode.window.showErrorMessage("zig-analyzer: building the executable to debug failed.", "Show Output").then((choice) => {
    if (choice) output.show(true);
  });
}

/**
 * Builds and debugs the executable of the file: in a project, the one `zig build` installs (the
 * user picks one of several); outside any project, the file itself.
 */
async function debug(arg?: unknown): Promise<void> {
  const file = target(arg);
  if (file === undefined) return;
  await vscode.workspace.saveAll(false);
  const root = buildRoot(file);
  const progress = { location: vscode.ProgressLocation.Window, title: "zig-analyzer: building" };
  if (root === undefined) {
    const bin = debugBinary(path.basename(file, ".zig"));
    const built = await vscode.window.withProgress(progress, () => zig(["build-exe", file, `-femit-bin=${bin}`], path.dirname(file)));
    if (built.code !== 0) return buildFailed(built.stderr);
    return startDebugging(bin, path.dirname(file));
  }
  const prefix = path.join(os.tmpdir(), "zig-analyzer-debug", "prefix");
  fs.rmSync(prefix, { recursive: true, force: true });
  const built = await vscode.window.withProgress(progress, () => zig(["build", "--prefix", prefix], root));
  if (built.code !== 0) return buildFailed(built.stderr);
  const bin = path.join(prefix, "bin");
  const exes = fs.existsSync(bin) ? fs.readdirSync(bin).filter((name) => !name.endsWith(".pdb")) : [];
  if (exes.length === 0) {
    void vscode.window.showErrorMessage("zig-analyzer: `zig build` installs no executable to debug.");
    return;
  }
  const exe = exes.length === 1 ? exes[0] : await vscode.window.showQuickPick(exes, { placeHolder: "Executable to debug" });
  if (exe !== undefined) await startDebugging(path.join(bin, exe), root);
}

/** Lists the tests of a Zig file under the item of the file, which exists while it has tests */
function updateTests(doc: vscode.TextDocument): void {
  if (doc.languageId !== "zig" || doc.uri.scheme !== "file" || !doc.fileName.endsWith(".zig")) return;
  const id = doc.uri.toString();
  const tests = entries.tests(doc.getText());
  if (tests.length === 0) {
    controller.items.delete(id);
    return;
  }
  let fileItem = controller.items.get(id);
  if (fileItem === undefined) {
    fileItem = controller.createTestItem(id, vscode.workspace.asRelativePath(doc.uri), doc.uri);
    controller.items.add(fileItem);
  }
  fileItem.children.replace(
    tests.map((test, i) => {
      const item = controller.createTestItem(`${id}#${i}`, test.name, doc.uri);
      const start = doc.positionAt(test.offset);
      item.range = new vscode.Range(start, doc.lineAt(start).range.end);
      return item;
    }),
  );
}

/**
 * Runs each test with `zig test <file> --test-filter <name>`; to debug one, builds the test
 * executable without running it and starts the debugger on it.
 */
async function runTests(request: vscode.TestRunRequest, token: vscode.CancellationToken, debugging: boolean): Promise<void> {
  await vscode.workspace.saveAll(false);
  const run = controller.createTestRun(request);
  const queue: vscode.TestItem[] = [];
  const add = (item: vscode.TestItem): void => {
    if (request.exclude?.includes(item)) return;
    if (item.parent) queue.push(item);
    else item.children.forEach(add);
  };
  if (request.include) request.include.forEach(add);
  else controller.items.forEach(add);

  for (const item of queue) {
    if (token.isCancellationRequested) {
      run.skipped(item);
      continue;
    }
    const file = item.uri!.fsPath;
    const cwd = buildRoot(file) ?? path.dirname(file);
    const args = ["test", file, "--test-filter", item.label];
    run.started(item);
    if (debugging) {
      const bin = debugBinary(`test-${path.basename(file, ".zig")}`);
      const built = await zig([...args, "--test-no-exec", `-femit-bin=${bin}`], cwd, token);
      if (built.code !== 0) run.errored(item, new vscode.TestMessage(built.stderr));
      else await startDebugging(bin, cwd);
      continue;
    }
    const began = Date.now();
    const result = await zig(args, cwd, token);
    run.appendOutput(result.stderr.replace(/\r?\n/g, "\r\n"), undefined, item);
    if (result.code === 0) run.passed(item, Date.now() - began);
    else if (token.isCancellationRequested) run.skipped(item);
    else run.failed(item, new vscode.TestMessage(result.stderr), Date.now() - began);
  }
  run.end();
}
