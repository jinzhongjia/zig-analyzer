// Checks that the settings contributed in package.json match the server's settings table in
// src/server/Config.zig: every server setting has a VS Code setting and the other way around.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = new URL("../../../", import.meta.url);
const config = readFileSync(fileURLToPath(new URL("src/server/Config.zig", root)), "utf8");
const table = config.slice(config.indexOf("const settings = [_]Setting{"));
const server = new Set(
  [...table.slice(0, table.indexOf("};")).matchAll(/\.section = "(\w+)", \.key = "(\w+)"/g)].map((m) => `${m[1]}.${m[2]}`),
);

const manifest = JSON.parse(readFileSync(fileURLToPath(new URL("../package.json", import.meta.url)), "utf8"));
const client = new Set(
  Object.keys(manifest.contributes.configuration.properties)
    .map((k) => k.slice("zig-analyzer.".length))
    .filter((k) => !k.startsWith("server.") && !k.startsWith("trace.")),
);

const missing = [...server].filter((k) => !client.has(k));
const extra = [...client].filter((k) => !server.has(k));
for (const k of missing) console.error(`missing in package.json: zig-analyzer.${k}`);
for (const k of extra) console.error(`not a server setting: zig-analyzer.${k}`);
if (missing.length || extra.length) process.exit(1);
console.log(`${server.size} settings match`);
