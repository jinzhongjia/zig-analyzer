import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";

export const section = "zig-analyzer";

/** Settings read by the extension itself; they are not sent to the server */
const clientOnly = ["server.", "trace."];

/** Every server setting key below `zig-analyzer.`, read from the extension's manifest */
function serverKeys(extension: vscode.Extension<unknown>): string[] {
  const properties: Record<string, unknown> = extension.packageJSON?.contributes?.configuration?.properties ?? {};
  return Object.keys(properties)
    .filter((k) => k.startsWith(section + "."))
    .map((k) => k.slice(section.length + 1))
    .filter((k) => !clientOnly.some((p) => k.startsWith(p)));
}

/**
 * The server settings as the JSON object the server expects (`{ "build": { "args": [...] } }`).
 * Only settings the user has set are included, so that the server's defaults and
 * `zig-analyzer.zon` apply to the others.
 */
export function serverSettings(extension: vscode.Extension<unknown>): Record<string, unknown> {
  const config = vscode.workspace.getConfiguration(section);
  const out: Record<string, Record<string, unknown>> = {};
  for (const key of serverKeys(extension)) {
    const i = config.inspect(key);
    if (i === undefined) continue;
    const value = i.workspaceFolderValue ?? i.workspaceValue ?? i.globalValue;
    if (value === undefined || value === null) continue;
    const dot = key.indexOf(".");
    const group = key.slice(0, dot);
    (out[group] ??= {})[key.slice(dot + 1)] = expandHome(key, value);
  }
  return out;
}

/** Settings holding paths that may start with `~/` */
const pathKeys = new Set(["zig.path", "zig.lib_path", "zig.global_cache_path", "zig.builtin_path", "log.file"]);

function expandHome(key: string, value: unknown): unknown {
  return pathKeys.has(key) && typeof value === "string" ? expandPath(value) : value;
}

export function expandPath(p: string): string {
  if (p === "~") return os.homedir();
  if (p.startsWith("~/") || p.startsWith("~\\")) return path.join(os.homedir(), p.slice(2));
  return p;
}

/** The server executable of `zig-analyzer.server.path`; undefined when it is not set */
export function configuredServer(): string | undefined {
  const configured = vscode.workspace.getConfiguration(section).get<string>("server.path")?.trim();
  return configured ? expandPath(configured) : undefined;
}

export function serverEnv(): NodeJS.ProcessEnv {
  const extra = vscode.workspace.getConfiguration(section).get<Record<string, string>>("server.extraEnv") ?? {};
  return { ...process.env, ...extra };
}
