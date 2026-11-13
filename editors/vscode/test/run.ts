// Runs the tests in a VS Code instance with only this extension: the smoke test on a copy of
// editors/test-project, against the `zig-analyzer` in PATH or the one in ZIG_ANALYZER, then the
// test of Install Server on fake releases of that executable, served from a local server. Needs
// Zig 0.17 in PATH. VSCODE_EXECUTABLE selects the VS Code executable; without it, a VS Code build
// is downloaded.
import * as cp from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runTests } from "@vscode/test-electron";
import { target } from "../src/install";
import { newKey, serve, writeRelease } from "./release";

const extensionDevelopmentPath = path.resolve(__dirname, "../..");

/** A copy of editors/test-project with the workspace settings `settings` */
function workspace(settings: Record<string, unknown>): string {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zig-analyzer-vscode-")));
  fs.cpSync(path.resolve(extensionDevelopmentPath, "../test-project"), dir, { recursive: true });
  fs.mkdirSync(path.join(dir, ".vscode"));
  fs.writeFileSync(path.join(dir, ".vscode", "settings.json"), JSON.stringify(settings));
  return dir;
}

async function launch(suite: string, dir: string, env: Record<string, string> = {}): Promise<void> {
  await runTests({
    vscodeExecutablePath: process.env.VSCODE_EXECUTABLE,
    extensionDevelopmentPath,
    extensionTestsPath: path.resolve(__dirname, suite),
    extensionTestsEnv: env,
    // Short: VS Code's IPC socket in it must fit the 103 bytes of a macOS socket path
    launchArgs: [dir, "--disable-extensions", "--user-data-dir", path.join(os.tmpdir(), `za-vscode-${process.pid}-${suite}`)],
  });
}

async function main(): Promise<void> {
  const server = process.env.ZIG_ANALYZER;
  const smoke = workspace({
    ...(server ? { "zig-analyzer.server.path": server } : {}),
    "zig-analyzer.inlay_hints.exclude_single_argument": false,
  });
  try {
    await launch("suite", smoke);
  } finally {
    fs.rmSync(smoke, { recursive: true, force: true });
  }

  const exe = server ?? cp.execFileSync(process.platform === "win32" ? "where" : "which", ["zig-analyzer"], { encoding: "utf8" }).split(/\r?\n/)[0];
  const releases = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zig-analyzer-releases-")));
  const key = newKey();
  const t = target()!;
  writeRelease(releases, "v9.9.9", { exe, target: t, key });
  writeRelease(releases, "v9.9.8", { exe, target: t, key });
  writeRelease(releases, "v9.9.6", { exe, target: t, key, comment: "v9.9.5" });
  const http = await serve(releases);
  http.latest = "v9.9.9";
  const dir = workspace({ "zig-analyzer.build.enable": false });
  try {
    await launch("install-suite", dir, {
      ZA_TEST_RELEASES: http.url,
      ZA_TEST_KEY: key.publicKey,
      ZA_TEST_SERVER: path.resolve(exe),
      ZA_TEST_TARGET: t,
    });
  } finally {
    await http.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(releases, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
