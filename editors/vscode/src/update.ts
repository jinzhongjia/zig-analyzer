// The version file of the server releases (see docs/features/update-check.md): the extension
// fetches it to learn whether a newer release exists. Installing is always the user's choice.
import { download } from "./install";

/** Where the release metadata is served */
export const metadataUrl = "https://releases.zig-analyzer.dev/metadata.json";

/** A release tag, as `Install Server` accepts it */
const tagPattern = /^v\d+\.\d+\.\d+[0-9A-Za-z.-]*$/;

/** The latest stable release tag in metadata.json, or undefined when it is not one */
export function parseMetadata(body: string): string | undefined {
  let data: unknown;
  try {
    data = JSON.parse(body);
  } catch {
    return undefined;
  }
  if (typeof data !== "object" || data === null) return undefined;
  const { schema, latest } = data as { schema?: unknown; latest?: unknown };
  return schema === 1 && typeof latest === "string" && tagPattern.test(latest) ? latest : undefined;
}

/** The latest stable release tag in the metadata at `url`, or undefined when it cannot be read */
export async function fetchLatest(url: string, signal?: AbortSignal): Promise<string | undefined> {
  try {
    return parseMetadata((await download(url, signal)).toString("utf8"));
  } catch {
    return undefined;
  }
}

interface Version {
  major: number;
  minor: number;
  patch: number;
  pre: string[];
}

function parseVersion(v: string): Version | undefined {
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(v.trim());
  if (m === null) return undefined;
  return {
    major: Number(m[1]),
    minor: Number(m[2]),
    patch: Number(m[3]),
    pre: m[4] === undefined ? [] : m[4].split("."),
  };
}

/**
 * Compares two versions as SemVer does (`v` optional, build metadata ignored): negative when `a`
 * is older than `b`, 0 when they are equal, positive when newer; undefined when either is not a
 * version. A version with a pre-release (`0.2.0-rc.1`, `0.2.0-dev`) is older than its release.
 */
export function compareVersions(a: string, b: string): number | undefined {
  const va = parseVersion(a);
  const vb = parseVersion(b);
  if (va === undefined || vb === undefined) return undefined;
  for (const k of ["major", "minor", "patch"] as const) {
    if (va[k] !== vb[k]) return va[k] < vb[k] ? -1 : 1;
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

/** The release notes of a tag */
export function releaseUrl(tag: string): string {
  return `https://github.com/jinzhongjia/zig-analyzer/releases/tag/${encodeURIComponent(tag)}`;
}
