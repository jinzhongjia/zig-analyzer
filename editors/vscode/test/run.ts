// Runs the smoke test in a VS Code instance with only this extension, on a copy of
// editors/test-project, against the `zig-analyzer` in PATH or the one in ZIG_ANALYZER. Needs Zig
// 0.17 in PATH. VSCODE_EXECUTABLE selects the VS Code executable; without it, a VS Code build is
// downloaded.
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runTests } from "@vscode/test-electron";

async function main(): Promise<void> {
  const extensionDevelopmentPath = path.resolve(__dirname, "../..");
  const workspace = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zig-analyzer-vscode-")));
  fs.cpSync(path.resolve(extensionDevelopmentPath, "../test-project"), workspace, { recursive: true });
  const settings = path.join(workspace, ".vscode");
  fs.mkdirSync(settings);
  const server = process.env.ZIG_ANALYZER;
  fs.writeFileSync(
    path.join(settings, "settings.json"),
    JSON.stringify({
      ...(server ? { "zig-analyzer.server.path": server } : {}),
      "zig-analyzer.inlay_hints.exclude_single_argument": false,
    }),
  );
  try {
    await runTests({
      vscodeExecutablePath: process.env.VSCODE_EXECUTABLE,
      extensionDevelopmentPath,
      extensionTestsPath: path.resolve(__dirname, "suite"),
      launchArgs: [workspace, "--disable-extensions", "--user-data-dir", path.join(os.tmpdir(), `zig-analyzer-vscode-user-${process.pid}`)],
    });
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
