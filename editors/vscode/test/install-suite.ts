import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { State } from "vscode-languageclient/node";
import type { Api } from "../src/extension";

// Test of **Install Server** in VS Code, with fake releases that test/run.ts serves:
// ZA_TEST_RELEASES is their URL, ZA_TEST_KEY their key, ZA_TEST_SERVER a zig-analyzer executable,
// ZA_TEST_TARGET the release target. The latest release is v9.9.9; v9.9.8 is another one and
// v9.9.6 is signed for v9.9.5.

const results: string[] = [];
let failures = 0;

function check(cond: unknown, what: string): void {
  results.push(`${cond ? "ok  " : "FAIL"} ${what}`);
  if (!cond) failures++;
}

async function poll<T>(f: () => T | Thenable<T>, ok: (v: T) => unknown, ms = 30_000): Promise<T> {
  const deadline = Date.now() + ms;
  for (;;) {
    const v = await f();
    if (ok(v) || Date.now() > deadline) return v;
    await new Promise((r) => setTimeout(r, 100));
  }
}

export async function run(): Promise<void> {
  const env = process.env;
  const api = await vscode.extensions.getExtension<Api>("jinzhongjia.zig-analyzer")!.activate();
  api.setReleaseSource({ releases: env.ZA_TEST_RELEASES!, publicKey: env.ZA_TEST_KEY! });
  const config = () => vscode.workspace.getConfiguration("zig-analyzer");
  const dir = api.installDir();
  const release = (tag: string, optimize: string) => `zig-analyzer-${tag}-${env.ZA_TEST_TARGET}-${optimize}`;
  const exe = (name: string) => path.join(dir, name, "zig-analyzer");
  const install = (options: object) => vscode.commands.executeCommand<string | undefined>("zig-analyzer.installServer", options);
  const running = () => poll(() => api.client(), (c) => c?.state === State.Running);
  const answers = async () => (await api.client()?.sendRequest<{ revision?: unknown } | null>("zig-analyzer/status"))?.revision !== undefined;

  // No zig-analyzer in PATH and no install
  const searchPath = (env.PATH ?? "").split(path.delimiter).filter((d) => !fs.existsSync(path.join(d, "zig-analyzer")));
  env.PATH = searchPath.join(path.delimiter);
  check(config().get("server.path") === "", "zig-analyzer.server.path is not set");
  // Restarting a client whose server failed to start must not reject, which would start no new server
  const restart = () =>
    Promise.resolve(vscode.commands.executeCommand("zig-analyzer.restartServer")).then(
      () => "",
      (err: Error) => err.message,
    );
  for (const n of [1, 2]) {
    const error = await restart();
    check(error === "", `restart ${n} of a server that fails to start succeeds (${error})`);
  }
  check(api.command() === "zig-analyzer" && api.client()?.state !== State.Running, "without an install or PATH entry, the server from PATH does not start");
  check(!fs.existsSync(dir), "nothing is downloaded before Install Server runs");

  // Install Server installs the latest release and starts it
  const latest = await install({});
  check(latest === exe(release("v9.9.9", "ReleaseSafe")), `Install Server installs the latest release (${latest})`);
  check((await running())?.state === State.Running && api.command() === latest, "the installed server starts");
  check(await answers(), "the installed server answers");

  // Installing another release restarts the server with it and removes the previous one
  const first = api.client();
  const fast = await install({ version: "v9.9.8", optimize: "ReleaseFast" });
  check(fast === exe(release("v9.9.8", "ReleaseFast")), "Install Server installs a given release and mode");
  check(api.client() !== first && (await running())?.state === State.Running && api.command() === fast, "the server restarts with the new install");
  check(!fs.existsSync(path.dirname(latest!)), "the previous release is removed");
  check(await answers(), "the restarted server answers");

  // Installing it again changes nothing
  const second = api.client();
  check((await install({ version: "v9.9.8", optimize: "ReleaseFast" })) === fast && api.client() === second, "reinstalling the running release keeps the server");

  // A rejected install keeps the server
  check((await install({ version: "v9.9.6" })) === undefined, "a release signed for another tag is rejected");
  check(api.client() === second && api.command() === fast && fs.existsSync(fast!), "a rejected install keeps the installed server running");
  check(!fs.readdirSync(dir).some((e) => e.startsWith(".tmp")), "a rejected install leaves no temporary directory");

  // One install at a time
  const pending = api.install({ version: "v9.9.8", optimize: "ReleaseSafe" });
  const busy = await api.install({}).then(
    () => "",
    (err: Error) => err.message,
  );
  check(busy === "an install is already running", "a second install while one runs is rejected");
  check((await pending).release === release("v9.9.8", "ReleaseSafe"), "the install that runs completes");
  await running();

  // zig-analyzer.server.path comes first and stays in use after an install
  await config().update("server.path", env.ZA_TEST_SERVER, vscode.ConfigurationTarget.Workspace);
  await vscode.commands.executeCommand("zig-analyzer.restartServer");
  check((await running())?.state === State.Running && api.command() === env.ZA_TEST_SERVER, "zig-analyzer.server.path comes before the install");
  const configured = api.client();
  const third = await install({});
  check(third === exe(release("v9.9.9", "ReleaseSafe")) && api.client() === configured && api.command() === env.ZA_TEST_SERVER, "an install keeps the server of zig-analyzer.server.path");

  // The install comes before PATH; without it the server is that of PATH
  const bin = path.join(path.dirname(dir), "bin");
  fs.mkdirSync(bin, { recursive: true });
  fs.symlinkSync(env.ZA_TEST_SERVER!, path.join(bin, "zig-analyzer"));
  env.PATH = [bin, ...searchPath].join(path.delimiter);
  await config().update("server.path", undefined, vscode.ConfigurationTarget.Workspace);
  await vscode.commands.executeCommand("zig-analyzer.restartServer");
  check((await running())?.state === State.Running && api.command() === third, "the install comes before PATH");
  fs.rmSync(dir, { recursive: true });
  await vscode.commands.executeCommand("zig-analyzer.restartServer");
  check((await running())?.state === State.Running && api.command() === "zig-analyzer", "without an install the server is that of PATH");

  console.log(results.join("\n"));
  if (failures > 0) throw new Error(`${failures} checks failed`);
  console.log("all install checks passed");
}
