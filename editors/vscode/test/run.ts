// Runs the smoke test in a VS Code instance with only this extension, against the
// `zig-analyzer` in PATH or the one in ZIG_ANALYZER. VSCODE_EXECUTABLE selects the VS Code
// executable; without it, a VS Code build is downloaded.
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runTests } from "@vscode/test-electron";

async function main(): Promise<void> {
  const extensionDevelopmentPath = path.resolve(__dirname, "../..");
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "zig-analyzer-vscode-"));
  fs.writeFileSync(
    path.join(workspace, "main.zig"),
    'const std = @import("std");\n\npub fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n\npub fn main() void {\n    const x   = add(1, 2);\n    std.debug.print("{}\\n", .{x});\n}\n',
  );
  const settings = path.join(workspace, ".vscode");
  fs.mkdirSync(settings);
  const server = process.env.ZIG_ANALYZER;
  fs.writeFileSync(
    path.join(settings, "settings.json"),
    JSON.stringify({ ...(server ? { "zig-analyzer.server.path": server } : {}), "zig-analyzer.inlay_hints.parameters": false }),
  );
  try {
    await runTests({
      vscodeExecutablePath: process.env.VSCODE_EXECUTABLE,
      extensionDevelopmentPath,
      extensionTestsPath: path.resolve(__dirname, "suite"),
      launchArgs: [workspace, "--disable-extensions", "--user-data-dir", path.join(workspace, ".user-data")],
    });
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
