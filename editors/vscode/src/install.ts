// Installs a release of the server from GitHub into a directory: `<dir>/<release>/zig-analyzer`,
// with `<dir>/current` naming the release in use. A release is installed only when the minisign
// signature of its SHA256SUMS verifies with the release key, the trusted comment of the signature
// names the release (`zig-analyzer <tag>`), and the archive has the SHA-256 that SHA256SUMS lists
// for it.
import * as cp from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
// Not `node:http(s)`: VS Code applies the proxy settings to the `http` and `https` modules
import * as http from "http";
import * as https from "https";
import { unpack } from "./archive";
import * as minisign from "./minisign";

export const optimizeModes = ["ReleaseSafe", "ReleaseFast"] as const;
export type Optimize = (typeof optimizeModes)[number];

/** Where releases come from: the release page and the key that signs them */
export interface ReleaseSource {
  releases: string;
  /** The base64 line of `minisign.pub` */
  publicKey: string;
}

/** The zig-analyzer releases, signed with the key of `minisign.pub` in the repository root */
export const github: ReleaseSource = {
  releases: "https://github.com/jinzhongjia/zig-analyzer/releases",
  publicKey: "RWRbma3B4tRgvIsJxiSxTvwoOWB6wvqxTEDgWVaJk0XMSeW9THbHBVj+",
};

export interface InstallOptions {
  /** A release tag such as `v0.1.1`; the latest release when unset */
  version?: string;
  optimize?: Optimize;
}

export interface Installed {
  exe: string;
  /** `zig-analyzer-<tag>-<arch>-<os>-<optimize>` */
  release: string;
}

export interface Result extends Installed {
  tag: string;
  optimize: Optimize;
  /** False when the release was installed already */
  downloaded: boolean;
}

export interface Progress {
  /** `transient` holds for messages that the next one replaces, such as download percentages */
  report(message: string, transient?: boolean): void;
  signal?: AbortSignal;
}

const exeName = process.platform === "win32" ? "zig-analyzer.exe" : "zig-analyzer";
const tagPattern = /^v\d+\.\d+\.\d+[0-9A-Za-z.-]*$/;
/** `zig-analyzer-<tag>-<arch>-<os>-<optimize>`; the arch may be `x86_64` */
const releasePattern = /^zig-analyzer-v[0-9A-Za-z._-]+$/;

/** `<arch>-<os>` of the release archive for this system; undefined when there is none */
export function target(): string | undefined {
  const arch = ({ x64: "x86_64", arm64: "aarch64" } as Record<string, string>)[process.arch];
  const os = ({ linux: "linux", darwin: "macos", win32: "windows" } as Record<string, string>)[process.platform];
  return arch && os ? `${arch}-${os}` : undefined;
}

/** The release installed in `dir`, when there is one */
export function installed(dir: string): Installed | undefined {
  let release: string;
  try {
    release = fs.readFileSync(path.join(dir, "current"), "utf8").split(/\r?\n/)[0].trim();
  } catch {
    return undefined;
  }
  if (!releasePattern.test(release)) return undefined;
  const exe = path.join(dir, release, exeName);
  try {
    if (!fs.statSync(exe).isFile()) return undefined;
    fs.accessSync(exe, fs.constants.X_OK);
  } catch {
    return undefined;
  }
  return { exe, release };
}

/** Removes the releases in `dir` other than `keep`; a release whose server still runs on Windows stays */
export async function removeOthers(dir: string, keep: string): Promise<void> {
  let entries: string[];
  try {
    entries = await fs.promises.readdir(dir);
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry.startsWith("zig-analyzer-") && entry !== keep) {
      await fs.promises.rm(path.join(dir, entry), { recursive: true, force: true, maxRetries: 3 }).catch(() => {});
    }
  }
}

/** Installs a release into `dir` */
export async function install(dir: string, options: InstallOptions, source: ReleaseSource, progress: Progress): Promise<Result> {
  const optimize = options.optimize ?? "ReleaseSafe";
  if (!optimizeModes.includes(optimize)) throw new Error(`unknown optimize mode ${optimize}`);
  const version = options.version?.trim() || undefined;
  if (version !== undefined && !tagPattern.test(version)) {
    throw new Error(`"${version}" is not a release tag (such as v0.1.1)`);
  }
  const system = target();
  if (system === undefined) {
    throw new Error(`there is no release for ${process.platform} ${process.arch}: build zig-analyzer from source and set zig-analyzer.server.path`);
  }
  const key = minisign.publicKey(source.publicKey);

  await fs.promises.mkdir(dir, { recursive: true });
  const tmp = await fs.promises.mkdtemp(path.join(dir, ".tmp-"));
  try {
    progress.report(version === undefined ? "looking up the latest release" : `looking up ${version}`);
    const base = version === undefined ? `${source.releases}/latest/download` : `${source.releases}/download/${version}`;
    const sums = await download(`${base}/SHA256SUMS`, progress.signal);
    const signature = await download(`${base}/SHA256SUMS.minisig`, progress.signal);
    let comment: string;
    try {
      comment = minisign.verify(sums, signature.toString("utf8"), key);
    } catch (err) {
      throw new Error(`SHA256SUMS: the signature does not verify with the release key (${(err as Error).message})`);
    }
    const tag = /^zig-analyzer (v\d+\.\d+\.\d+[0-9A-Za-z.-]*)$/.exec(comment)?.[1];
    if (tag === undefined) throw new Error(`SHA256SUMS: unexpected trusted comment "${comment}"`);
    if (version !== undefined && tag !== version) throw new Error(`SHA256SUMS is signed for ${tag}, not ${version}`);

    const release = `zig-analyzer-${tag}-${system}-${optimize}`;
    const zip = process.platform === "win32";
    const archiveName = release + (zip ? ".zip" : ".tar.gz");
    let hash: string | undefined;
    for (const line of sums.toString("utf8").split("\n")) {
      const m = /^([0-9a-fA-F]{64}) {2}(.+)$/.exec(line.replace(/\r$/, ""));
      if (m && m[2] === archiveName) hash = m[1].toLowerCase();
    }
    if (hash === undefined) throw new Error(`${tag} has no ${archiveName}`);

    const current = installed(dir);
    if (current?.release === release) return { ...current, tag, optimize, downloaded: false };

    progress.report(`downloading ${archiveName}`);
    // From the checked release: `latest` may have moved on since SHA256SUMS was downloaded
    let percent = 0;
    const archive = await download(`${source.releases}/download/${tag}/${archiveName}`, progress.signal, (received, total) => {
      const p = total > 0 ? Math.floor((received * 100) / total) : 0;
      if (p > percent) {
        percent = p;
        progress.report(`downloading ${archiveName} (${p}%)`, true);
      }
    });
    if (crypto.createHash("sha256").update(archive).digest("hex") !== hash) {
      throw new Error(`${archiveName}: the SHA-256 does not match SHA256SUMS`);
    }

    progress.report(`unpacking ${archiveName}`);
    await unpack(archive, zip, release, tmp);
    const unpacked = path.join(tmp, release, exeName);
    if (!fs.existsSync(unpacked)) throw new Error(`${archiveName} has no ${release}/${exeName}`);
    if (!zip) await fs.promises.chmod(unpacked, 0o755);
    await run(unpacked, ["--version"]).catch((err: Error) => {
      throw new Error(`the downloaded server does not run: ${err.message}`);
    });

    const dest = path.join(dir, release);
    await fs.promises.rm(dest, { recursive: true, force: true, maxRetries: 3 });
    await rename(path.join(tmp, release), dest);
    const currentFile = path.join(dir, "current");
    await fs.promises.writeFile(currentFile + ".tmp", release + "\n");
    await rename(currentFile + ".tmp", currentFile);
    return { exe: path.join(dest, exeName), release, tag, optimize, downloaded: true };
  } finally {
    await fs.promises.rm(tmp, { recursive: true, force: true, maxRetries: 3 }).catch(() => {});
  }
}

/** Renames, retrying while another process (such as a virus scanner on Windows) has the file open */
async function rename(from: string, to: string): Promise<void> {
  for (let attempt = 0; ; attempt++) {
    try {
      await fs.promises.rename(from, to);
      return;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (attempt >= 20 || !["EPERM", "EACCES", "EBUSY"].includes(code ?? "")) throw err;
      await new Promise((r) => setTimeout(r, 100));
    }
  }
}

function run(exe: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    cp.execFile(exe, args, { timeout: 30_000, windowsHide: true }, (err, _stdout, stderr) => {
      if (err) reject(new Error(stderr.trim() || err.message));
      else resolve();
    });
  });
}

/** Downloads `url`, following redirects (never from https to http) */
export function download(
  url: string,
  signal?: AbortSignal,
  onProgress?: (received: number, total: number) => void,
  redirects = 10,
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const fail = (why: string) => reject(new Error(`cannot download ${url}: ${why}`));
    let u: URL;
    try {
      u = new URL(url);
    } catch {
      return fail("not a URL");
    }
    const get = u.protocol === "https:" ? https.get : u.protocol === "http:" ? http.get : undefined;
    if (get === undefined) return fail(`unsupported protocol ${u.protocol}`);
    if (signal?.aborted) return reject(new Error("canceled"));
    const req = get(u, { headers: { "User-Agent": "zig-analyzer-vscode" }, signal }, (res) => {
      const status = res.statusCode ?? 0;
      const location = res.headers.location;
      if ([301, 302, 303, 307, 308].includes(status) && location) {
        res.resume();
        const next = new URL(location, u);
        if (redirects === 0) return fail("too many redirects");
        if (u.protocol === "https:" && next.protocol !== "https:") return fail(`redirected to ${next.protocol}`);
        return resolve(download(next.toString(), signal, onProgress, redirects - 1));
      }
      if (status !== 200) {
        res.resume();
        return fail(`HTTP ${status}`);
      }
      const total = Number(res.headers["content-length"] ?? 0);
      const chunks: Buffer[] = [];
      let received = 0;
      res.on("data", (chunk: Buffer) => {
        chunks.push(chunk);
        received += chunk.length;
        onProgress?.(received, total);
      });
      res.on("error", (err) => (signal?.aborted ? reject(new Error("canceled")) : fail(err.message)));
      res.on("close", () => {
        if (!res.complete) return signal?.aborted ? reject(new Error("canceled")) : fail("the connection closed early");
        resolve(Buffer.concat(chunks));
      });
    });
    req.setTimeout(60_000, () => req.destroy(new Error("timed out")));
    req.on("error", (err) => (signal?.aborted ? reject(new Error("canceled")) : fail(err.message)));
  });
}
