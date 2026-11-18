// Builds metadata.json for the release server (see updates/README.md):
//   node updates/metadata.mjs --tag v0.1.2 --packaging-zig 0.17.1 \
//     --artifacts dist --output metadata.json [--existing old-metadata.json]
//
// The versions already in `--existing` are kept, so the file holds every release. `latest` is
// the newest stable tag; a pre-release is listed but does not become `latest`.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const tagPattern = /^v\d+\.\d+\.\d+[0-9A-Za-z.-]*$/;
const metadataSchema = 1;

/** The Zig versions the server supports, from `supported_versions` in `ZigEnv.zig` */
export function supportedZig(source) {
  const match = /pub const supported_versions = \[_\]\[\]const u8\{([^}]*)\};/.exec(source);
  if (match === null) throw new Error("no supported_versions in the Zig source");
  const versions = [...match[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  if (versions.length === 0) throw new Error("supported_versions is empty");
  return versions;
}

/** The artifacts of one release, from the archive names in `dir` */
export function artifacts(dir, tag) {
  const prefix = `zig-analyzer-${tag}-`;
  const list = [];
  for (const name of fs.readdirSync(dir)) {
    if (!name.startsWith(prefix)) continue;
    let rest;
    if (name.endsWith(".tar.gz")) rest = name.slice(prefix.length, -".tar.gz".length);
    else if (name.endsWith(".zip")) rest = name.slice(prefix.length, -".zip".length);
    else continue;
    const match = /^(.+)-(ReleaseSafe|ReleaseFast)$/.exec(rest);
    if (match === null) continue;
    list.push({
      target: match[1],
      optimize: match[2],
      file: name,
      size: fs.statSync(path.join(dir, name)).size,
    });
  }
  const optimizeOrder = { ReleaseSafe: 0, ReleaseFast: 1 };
  list.sort((a, b) => a.target.localeCompare(b.target) || optimizeOrder[a.optimize] - optimizeOrder[b.optimize]);
  return list;
}

function parseVersion(tag) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(tag);
  if (match === null) return undefined;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    pre: match[4] === undefined ? [] : match[4].split("."),
  };
}

/** SemVer order: negative when `a` is older than `b`, 0 when equal, positive when newer */
export function compareTags(a, b) {
  const va = parseVersion(a);
  const vb = parseVersion(b);
  if (va === undefined || vb === undefined) throw new Error(`not a release tag: ${va === undefined ? a : b}`);
  for (const key of ["major", "minor", "patch"]) {
    if (va[key] !== vb[key]) return va[key] < vb[key] ? -1 : 1;
  }
  if (va.pre.length === 0 && vb.pre.length === 0) return 0;
  if (va.pre.length === 0) return 1;
  if (vb.pre.length === 0) return -1;
  for (let i = 0; i < Math.max(va.pre.length, vb.pre.length); i++) {
    const x = va.pre[i];
    const y = vb.pre[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const xn = /^\d+$/.test(x);
    const yn = /^\d+$/.test(y);
    if (xn && yn) {
      if (Number(x) !== Number(y)) return Number(x) < Number(y) ? -1 : 1;
    } else if (xn !== yn) {
      return xn ? -1 : 1;
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}

/** Adds `entry` to `existing`, sorts the versions, and recomputes `latest` */
export function buildMetadata(existing, entry) {
  if (existing !== undefined && (existing.schema !== metadataSchema || !Array.isArray(existing.versions))) {
    throw new Error("existing metadata.json has another schema");
  }
  const versions = (existing?.versions ?? []).filter((v) => v.tag !== entry.tag);
  versions.push(entry);
  versions.sort((a, b) => compareTags(b.tag, a.tag));
  const latest = versions.find((v) => !v.prerelease)?.tag ?? null;
  return { schema: metadataSchema, latest, versions };
}

function parseArgs(args) {
  const options = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (!arg.startsWith("--") || i + 1 >= args.length) throw new Error(`usage: metadata.mjs --tag <tag> --packaging-zig <version> --artifacts <dir> --output <file>`);
    options[arg.slice(2)] = args[++i];
  }
  return options;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const tag = options.tag;
  if (tag === undefined || !tagPattern.test(tag)) throw new Error(`not a release tag: ${tag}`);
  if (options["packaging-zig"] === undefined) throw new Error("--packaging-zig is missing");
  if (options.artifacts === undefined) throw new Error("--artifacts is missing");
  if (options.output === undefined) throw new Error("--output is missing");

  const source = fs.readFileSync(options["supported-source"] ?? "src/project/ZigEnv.zig", "utf8");
  const existing = options.existing !== undefined && fs.existsSync(options.existing) ? JSON.parse(fs.readFileSync(options.existing, "utf8")) : undefined;
  const notesBase = options["notes-base"] ?? "https://github.com/jinzhongjia/zig-analyzer/releases/tag";
  const entry = {
    tag,
    released: options.released ?? new Date().toISOString(),
    prerelease: tag.includes("-"),
    zig: {
      supported: supportedZig(source),
      packaging: options["packaging-zig"],
    },
    artifacts: artifacts(options.artifacts, tag),
  };
  if (notesBase !== "") entry.notes = `${notesBase}/${tag}`;
  const metadata = buildMetadata(existing, entry);
  fs.writeFileSync(options.output, JSON.stringify(metadata, null, 2) + "\n");
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (err) {
    console.error(`metadata: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  }
}
