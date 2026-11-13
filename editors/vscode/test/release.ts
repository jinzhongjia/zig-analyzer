// Fake releases for the tests, made with the Node that runs the tests (not VS Code's), whose
// OpenSSL has the BLAKE2b-512 that minisign signatures sign: so the signatures do not come from
// the extension's own BLAKE2b.
import * as cp from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";

export interface Key {
  /** The base64 line of a `minisign.pub` */
  publicKey: string;
  keyId: Buffer;
  privateKey: crypto.KeyObject;
}

export function newKey(): Key {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  const keyId = crypto.randomBytes(8);
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(12);
  return { publicKey: Buffer.concat([Buffer.from("Ed"), keyId, raw]).toString("base64"), keyId, privateKey };
}

/** The minisign signature (`.minisig` text) of `message` by `key`, with the trusted comment `comment` */
export function sign(message: Buffer, key: Key, comment: string): string {
  const hash = crypto.createHash("blake2b512").update(message).digest();
  const sig = crypto.sign(null, hash, key.privateKey);
  const global = crypto.sign(null, Buffer.concat([sig, Buffer.from(comment)]), key.privateKey);
  return [
    "untrusted comment: signature from a test key",
    Buffer.concat([Buffer.from("ED"), key.keyId, sig]).toString("base64"),
    `trusted comment: ${comment}`,
    global.toString("base64"),
    "",
  ].join("\n");
}

export interface ReleaseOptions {
  /** The executable in the archives */
  exe: string;
  target: string;
  optimize?: string[];
  key: Key;
  /** The tag in the trusted comment; `tag` by default */
  comment?: string;
}

/**
 * Writes the release `tag` to `<root>/download/<tag>`: an archive of each optimize mode holding
 * `zig-analyzer-<tag>-<target>-<optimize>/zig-analyzer`, SHA256SUMS, and its signature
 */
export function writeRelease(root: string, tag: string, o: ReleaseOptions): string {
  const dir = path.join(root, "download", tag);
  fs.mkdirSync(dir, { recursive: true });
  const stage = fs.mkdtempSync(path.join(root, "stage-"));
  const sums: string[] = [];
  for (const optimize of o.optimize ?? ["ReleaseSafe", "ReleaseFast"]) {
    const name = `zig-analyzer-${tag}-${o.target}-${optimize}`;
    fs.mkdirSync(path.join(stage, name));
    fs.copyFileSync(o.exe, path.join(stage, name, "zig-analyzer"));
    fs.chmodSync(path.join(stage, name, "zig-analyzer"), 0o755);
    fs.writeFileSync(path.join(stage, name, "README.md"), "fake release\n");
    const archive = path.join(dir, `${name}.tar.gz`);
    // macOS tar adds AppleDouble `._` entries for extended attributes unless told not to
    cp.execFileSync("tar", ["-czf", archive, "-C", stage, name], { env: { ...process.env, COPYFILE_DISABLE: "1" } });
    sums.push(`${crypto.createHash("sha256").update(fs.readFileSync(archive)).digest("hex")}  ${name}.tar.gz`);
  }
  fs.rmSync(stage, { recursive: true });
  const sumsText = Buffer.from(sums.join("\n") + "\n");
  fs.writeFileSync(path.join(dir, "SHA256SUMS"), sumsText);
  fs.writeFileSync(path.join(dir, "SHA256SUMS.minisig"), sign(sumsText, o.key, `zig-analyzer ${o.comment ?? tag}`));
  return dir;
}

export interface ReleaseServer {
  url: string;
  /** The tag `/latest/download` redirects to */
  latest: string;
  /** The paths of the requests */
  requests: string[];
  close(): Promise<void>;
}

/**
 * Serves the releases in `<root>/download` as GitHub does: `/latest/download/<file>` redirects to
 * `/download/<latest>/<file>`, which redirects to `/objects/<tag>/<file>`, the file
 */
export async function serve(root: string): Promise<ReleaseServer> {
  const state = { latest: "", requests: [] as string[] };
  const server = http.createServer((req, res) => {
    const url = req.url ?? "/";
    state.requests.push(url);
    let m: RegExpExecArray | null;
    if ((m = /^\/latest\/download\/([^/]+)$/.exec(url))) {
      res.writeHead(302, { Location: `/download/${state.latest}/${m[1]}` }).end();
    } else if ((m = /^\/download\/([^/]+)\/([^/]+)$/.exec(url))) {
      res.writeHead(302, { Location: `/objects/${m[1]}/${m[2]}` }).end();
    } else if ((m = /^\/objects\/([^/]+)\/([^/]+)$/.exec(url)) && fs.existsSync(path.join(root, "download", m[1], m[2]))) {
      const data = fs.readFileSync(path.join(root, "download", m[1], m[2]));
      res.writeHead(200, { "Content-Length": data.length }).end(data);
    } else {
      res.writeHead(404).end();
    }
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;
  return Object.assign(state, {
    url: `http://127.0.0.1:${port}`,
    close: () => new Promise<void>((r) => server.close(() => r())),
  });
}
