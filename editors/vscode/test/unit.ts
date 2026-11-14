// Tests of the release installer that need no VS Code: BLAKE2b-512 and minisign verification,
// unpacking, and installs of fake releases from a local server. Runs on macOS and Linux with
// `tar` (and `zip`, when installed) in PATH:
//   node out-test/test/unit.js
import * as cp from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { crc32, tarEntries, unpack, zipEntries } from "../src/archive";
import * as installer from "../src/install";
import * as minisign from "../src/minisign";
import * as views from "../src/views";
import { newKey, serve, sign, writeRelease } from "./release";

const results: string[] = [];
let failures = 0;

function check(cond: unknown, what: string): void {
  results.push(`${cond ? "ok  " : "FAIL"} ${what}`);
  if (!cond) failures++;
}

/** The message `f` throws (rejects with); '' when it does not */
async function thrown(f: () => unknown): Promise<string> {
  try {
    await f();
    return "";
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  }
}

const hex = (b: Buffer) => b.toString("hex");
const fixtures = path.join(__dirname, "../../test/fixtures");
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zig-analyzer-unit-")));

function blake2b(): void {
  // RFC 7693, appendix A, and the hash of no bytes
  check(
    hex(minisign.blake2b512(Buffer.from("abc"))) ===
      "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
    'BLAKE2b-512("abc") of RFC 7693',
  );
  check(
    hex(minisign.blake2b512(Buffer.alloc(0))) ===
      "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce",
    "BLAKE2b-512 of no bytes",
  );
  // Around the block size of 128 bytes, and larger, against OpenSSL
  const data = crypto.randomBytes(100_000);
  const lengths = [1, 3, 127, 128, 129, 255, 256, 257, 1000, 100_000];
  check(
    lengths.every((n) => minisign.blake2b512(data.subarray(0, n)).equals(crypto.createHash("blake2b512").update(data.subarray(0, n)).digest())),
    `BLAKE2b-512 equals that of OpenSSL for ${lengths.join(", ")} bytes`,
  );
}

async function signatures(): Promise<void> {
  // RFC 8032, test 1: the key is read as an Ed25519 key
  const rfcKey = minisign.publicKey(
    Buffer.concat([Buffer.from("Ed"), Buffer.alloc(8), Buffer.from("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "hex")]).toString("base64"),
  );
  const rfcSig = Buffer.from(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    "hex",
  );
  check(crypto.verify(null, Buffer.alloc(0), rfcKey.key, rfcSig), "the Ed25519 key of RFC 8032 test 1 verifies its signature");

  const key = minisign.publicKey(installer.github.publicKey);
  const repoKey = fs.readFileSync(path.join(__dirname, "../../../../minisign.pub"), "utf8").split("\n")[1];
  check(repoKey === installer.github.publicKey, "the release key is that of minisign.pub");
  const sums = fs.readFileSync(path.join(fixtures, "SHA256SUMS"));
  const sig = fs.readFileSync(path.join(fixtures, "SHA256SUMS.minisig"), "utf8");
  check(minisign.verify(sums, sig, key) === "zig-analyzer v0.1.1", "the v0.1.1 SHA256SUMS verifies, signed for v0.1.1");
  check(minisign.verify(sums, sig.replace(/\n/g, "\r\n"), key) === "zig-analyzer v0.1.1", "a signature with CRLF lines verifies");
  const edited = Buffer.from(sums);
  edited[0] ^= 1;
  check((await thrown(() => minisign.verify(edited, sig, key))) === "the signature does not verify", "an edited SHA256SUMS does not verify");
  check(
    (await thrown(() => minisign.verify(sums, sig.replace("zig-analyzer v0.1.1", "zig-analyzer v0.1.2"), key))) ===
      "the signature of the trusted comment does not verify",
    "an edited trusted comment does not verify",
  );
  const other = newKey();
  check(
    (await thrown(() => minisign.verify(sums, sig, minisign.publicKey(other.publicKey)))) === "the signature is by another key",
    "another key does not verify",
  );
  // The signature of another key that has the release key's id
  const forged = { ...other, keyId: key.keyId };
  check(
    (await thrown(() => minisign.verify(sums, sign(sums, forged, "zig-analyzer v0.1.1"), key))) === "the signature does not verify",
    "a signature by another key with the key id of the release key does not verify",
  );
  // The legacy algorithm signs the message itself: not accepted
  const lines = sig.split("\n");
  const legacy = Buffer.from(lines[1], "base64");
  legacy.write("Ed", 0, "latin1");
  lines[1] = legacy.toString("base64");
  check((await thrown(() => minisign.verify(sums, lines.join("\n"), key))).includes("not of a prehashed"), "the legacy algorithm is rejected");
  check((await thrown(() => minisign.verify(sums, "garbage", key))) === "not a minisign signature", "a text that is no signature is rejected");
  check((await thrown(() => minisign.publicKey("RWQ="))) === "not a minisign public key", "a text that is no key is rejected");

  // A signature of the test helper (BLAKE2b of OpenSSL) verifies
  const msg = crypto.randomBytes(5000);
  check(minisign.verify(msg, sign(msg, other, "zig-analyzer v1.2.3"), minisign.publicKey(other.publicKey)) === "zig-analyzer v1.2.3", "a signature of the test helper verifies");
}

/** A tar header (ustar, or old GNU with `gnu`) */
function tarHeader(name: string, type: string, size: number, gnu = false, mode = 0o644): Buffer {
  const h = Buffer.alloc(512);
  h.write(name, 0, 100, "utf8");
  h.write(mode.toString(8).padStart(7, "0") + "\0", 100, "latin1");
  h.write("0000000\0", 108, "latin1");
  h.write("0000000\0", 116, "latin1");
  h.write(size.toString(8).padStart(11, "0") + "\0", 124, "latin1");
  h.write("00000000000\0", 136, "latin1");
  h.write("        ", 148, "latin1");
  h.write(type, 156, "latin1");
  h.write(gnu ? "ustar  \0" : "ustar\x0000", 257, "latin1");
  let sum = 0;
  for (const b of h) sum += b;
  h.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, "latin1");
  return h;
}

function tarFile(entries: { name: string; type?: string; data?: string; gnu?: boolean }[]): Buffer {
  const parts: Buffer[] = [];
  for (const e of entries) {
    const data = Buffer.from(e.data ?? "");
    parts.push(tarHeader(e.name, e.type ?? "0", data.length, e.gnu), data, Buffer.alloc((512 - (data.length % 512)) % 512));
  }
  return Buffer.concat([...parts, Buffer.alloc(1024)]);
}

/** A zip archive of stored entries */
function zipFile(entries: { name: string; data: string; crc?: number }[]): Buffer {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const e of entries) {
    const data = Buffer.from(e.data);
    const name = Buffer.from(e.name);
    const crc = e.crc ?? crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, name, data);
    centrals.push(central, name);
    offset += 30 + name.length + data.length;
  }
  const cd = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cd.length, 12);
  eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, eocd]);
}

/** The files below `dir`: relative path to content (directories map to null) and mode */
function tree(dir: string): Map<string, string> {
  const out = new Map<string, string>();
  const walk = (rel: string) => {
    for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) {
        out.set(r + "/", "");
        walk(r);
      } else {
        const st = fs.statSync(path.join(dir, r));
        out.set(r, `${(st.mode & 0o777).toString(8)} ${fs.readFileSync(path.join(dir, r), "utf8")}`);
      }
    }
  };
  walk("");
  return out;
}

async function archives(): Promise<void> {
  // A tree with names longer than the 100 bytes of a tar header, an empty directory, and an executable
  const root = "zig-analyzer-v1.2.3-x86_64-linux-ReleaseSafe";
  const src = path.join(tmp, "src");
  const deep = path.join(src, root, "zig-analyzer.dSYM", "Contents", "Resources", "Relocations", "x86_64-and-a-longer-name");
  fs.mkdirSync(deep, { recursive: true });
  fs.mkdirSync(path.join(src, root, "empty"));
  fs.writeFileSync(path.join(deep, "zig-analyzer-with-a-name-long-enough-for-more-than-155-bytes.yml"), "deep\n");
  fs.writeFileSync(path.join(src, root, "zig-analyzer"), "#!/bin/sh\n", { mode: 0o755 });
  fs.writeFileSync(path.join(src, root, "README.md"), "x".repeat(100_000));
  const expected = tree(src);
  check([...expected.keys()].some((k) => k.length > 155), "the test tree has a path longer than 155 bytes");

  // macOS tar adds AppleDouble `._` entries for extended attributes unless told not to
  const noMacMetadata = { ...process.env, COPYFILE_DISABLE: "1" };
  const bsd = cp.execFileSync("tar", ["--version"], { encoding: "utf8" }).includes("bsdtar");
  const formats = bsd ? ["gnutar", "pax", "ustar"] : ["gnu", "pax", "ustar"];
  for (const format of formats) {
    const file = path.join(tmp, `${format}.tar.gz`);
    const r = cp.spawnSync("tar", ["-czf", file, `--format=${format}`, "-C", src, root], { encoding: "utf8", env: noMacMetadata });
    const dest = path.join(tmp, `out-${format}`);
    // ustar has no long names: tar splits names longer than 100 bytes into the prefix field, and
    // leaves out (and fails on) a name that does not fit, after writing the other entries
    if (format === "ustar") {
      await unpack(fs.readFileSync(file), false, root, dest);
      const got = tree(dest);
      check(
        got.size > 0 && [...got].every(([k, v]) => expected.get(k) === v) && [...got.keys()].some((k) => k.length > 100),
        `${format} tar.gz (${bsd ? "bsdtar" : "GNU tar"}, status ${r.status}): the entries it holds unpack, with names in the prefix field`,
      );
      continue;
    }
    check(r.status === 0, `${format}: tar writes the tree (${r.stderr.trim()})`);
    await unpack(fs.readFileSync(file), false, root, dest);
    const got = tree(dest);
    check(got.size === expected.size && [...got].every(([k, v]) => expected.get(k) === v), `${format} tar.gz (${bsd ? "bsdtar" : "GNU tar"}): unpacked as packed`);
  }
  if (fs.existsSync("/usr/bin/zip") || cp.spawnSync("zip", ["-v"]).status === 0) {
    for (const [flag, what] of [["-9", "deflated"], ["-0", "stored"]]) {
      const file = path.join(tmp, `${what}.zip`);
      cp.execFileSync("zip", ["-qr", flag, file, root], { cwd: src });
      const dest = path.join(tmp, `out-${what}`);
      await unpack(fs.readFileSync(file), true, root, dest);
      const got = tree(dest);
      check(got.size === expected.size && [...got].every(([k, v]) => expected.get(k) === v), `zip (${what}): unpacked as packed`);
    }
  } else {
    results.push("skip zip: no zip in PATH");
  }

  const r = "zig-analyzer-v1";
  const bad = async (what: string, tar: Buffer, pattern: string) =>
    check((await thrown(() => tarEntries(tar, r))).includes(pattern), `tar: ${what} is rejected`);
  await bad("a path with ..", tarFile([{ name: `${r}/../x`, data: "x" }]), "invalid path");
  await bad("an absolute path", tarFile([{ name: `/${r}/x`, data: "x" }]), "invalid path");
  await bad("a path outside the root", tarFile([{ name: "other/x", data: "x" }]), "outside");
  await bad("a symbolic link", tarFile([{ name: `${r}/link`, type: "2" }]), "no file or directory");
  await bad("a hard link", tarFile([{ name: `${r}/link`, type: "1" }]), "no file or directory");
  await bad("a GNU long name with ..", tarFile([{ name: "././@LongLink", type: "L", data: `${r}/../../x\0`, gnu: true }, { name: "short", data: "x", gnu: true }]), "invalid path");
  await bad("a pax path outside the root", tarFile([{ name: "pax", type: "x", data: "16 path=other/x\n" }, { name: `${r}/x`, data: "x" }]), "outside");
  const good = tarFile([{ name: `${r}/`, type: "5" }, { name: `${r}/x`, data: "hello" }]);
  check(tarEntries(good, r).map((e) => e.name).join(",") === `${r}/,${r}/x`, "tar: a plain archive is read");
  await bad("an archive that ends early", good.subarray(0, 512 + 100), "ends early");
  const damaged = Buffer.from(good);
  damaged[0] ^= 1;
  await bad("a header with another checksum", damaged, "damaged");
  const zipBad = async (what: string, zip: Buffer, pattern: string) =>
    check((await thrown(() => zipEntries(zip, r))).includes(pattern), `zip: ${what} is rejected`);
  await zipBad("a path with ..", zipFile([{ name: `${r}/../x`, data: "x" }]), "invalid path");
  await zipBad("a path with a backslash", zipFile([{ name: `${r}\\x`, data: "x" }]), "invalid path");
  await zipBad("a path outside the root", zipFile([{ name: "other/x", data: "x" }]), "outside");
  await zipBad("an entry with another CRC", zipFile([{ name: `${r}/x`, data: "x", crc: 1 }]), "damaged entry");
  await zipBad("a file that is no zip", Buffer.from("not a zip archive at all"), "not a zip");
  check((await zipEntries(zipFile([{ name: `${r}/x`, data: "hello" }]), r))[0]?.data?.toString() === "hello", "zip: a plain archive is read");
}

async function installs(): Promise<void> {
  const target = installer.target();
  check(target !== undefined && /^(x86_64|aarch64)-(linux|macos)$/.test(target), `the release target is ${target}`);
  const key = newKey();
  const releases = path.join(tmp, "releases");
  const exe = path.join(tmp, "fake-server");
  fs.writeFileSync(exe, "#!/bin/sh\necho 0.0.0\n", { mode: 0o755 });
  const broken = path.join(tmp, "broken-server");
  fs.writeFileSync(broken, "#!/bin/sh\necho broken >&2\nexit 1\n", { mode: 0o755 });
  const base = { exe, target: target!, key };
  const server = await serve(releases);
  const source = { releases: server.url, publicKey: key.publicKey };
  const dir = path.join(tmp, "data");
  const progress = { report: () => {} };
  const run = (options: installer.InstallOptions, src = source) => thrown(() => installer.install(dir, options, src, progress));
  const leftovers = () => fs.existsSync(dir) && fs.readdirSync(dir).some((e) => e.startsWith(".tmp"));

  check(installer.installed(dir) === undefined, "without an install none is found");
  for (const t of ["x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos", "x86_64-windows", "aarch64-windows"]) {
    const name = `zig-analyzer-v1.2.3-rc.1-${t}-ReleaseFast`;
    fs.mkdirSync(path.join(dir, name), { recursive: true });
    fs.copyFileSync(exe, path.join(dir, name, "zig-analyzer"));
    fs.chmodSync(path.join(dir, name, "zig-analyzer"), 0o755);
    fs.writeFileSync(path.join(dir, "current"), name + "\n");
    check(installer.installed(dir)?.release === name, `an install for ${t} is found`);
    fs.rmSync(path.join(dir, name), { recursive: true });
  }
  fs.writeFileSync(path.join(dir, "current"), "../../etc\n");
  check(installer.installed(dir) === undefined, "a current file naming no release is ignored");
  fs.rmSync(path.join(dir, "current"));

  writeRelease(releases, "v9.9.7", { ...base, key: newKey() });
  check((await run({ version: "v9.9.7" })).includes("does not verify with the release key"), "a release signed with another key is rejected");
  writeRelease(releases, "v9.9.6", { ...base, comment: "v9.9.5" });
  check((await run({ version: "v9.9.6" })).includes("signed for v9.9.5, not v9.9.6"), "a release signed for another tag is rejected");
  const v994 = writeRelease(releases, "v9.9.4", { ...base, optimize: ["ReleaseSafe"] });
  check((await run({ version: "v9.9.4", optimize: "ReleaseFast" })).includes(`has no zig-analyzer-v9.9.4-${target}-ReleaseFast.tar.gz`), "a release without the archive is rejected");
  fs.appendFileSync(path.join(v994, `zig-analyzer-v9.9.4-${target}-ReleaseSafe.tar.gz`), "x");
  check((await run({ version: "v9.9.4" })).includes("the SHA-256 does not match SHA256SUMS"), "an archive with another SHA-256 is rejected");
  check((await run({ version: "v9.9.3" })).includes("HTTP 404"), "a release that does not exist is rejected");
  writeRelease(releases, "v9.9.2", { ...base, exe: broken });
  check((await run({ version: "v9.9.2" })).includes("the downloaded server does not run: broken"), "a release whose server does not run is rejected");
  check((await run({ version: "nightly" })).includes("is not a release tag"), "a version that is no tag is rejected");
  check((await run({ optimize: "Debug" as installer.Optimize })).includes("unknown optimize mode"), "an unknown optimize mode is rejected");
  check((await run({ version: "v9.9.8" }, { releases: "ftp://example.com", publicKey: key.publicKey })).includes("unsupported protocol"), "a release page of another protocol is rejected");
  const aborted = new AbortController();
  aborted.abort();
  writeRelease(releases, "v9.9.1", base);
  check(
    (await thrown(() => installer.install(dir, { version: "v9.9.1" }, source, { report: () => {}, signal: aborted.signal }))) === "canceled",
    "a canceled install is rejected",
  );
  check(installer.installed(dir) === undefined, "rejected installs install nothing");
  check(!leftovers(), "rejected installs leave no temporary directory");

  writeRelease(releases, "v9.9.8", base);
  writeRelease(releases, "v9.9.9", base);
  server.latest = "v9.9.9";
  server.requests.length = 0;
  const latest = await installer.install(dir, {}, source, progress);
  const name = `zig-analyzer-v9.9.9-${target}-ReleaseSafe`;
  check(latest.tag === "v9.9.9" && latest.release === name && latest.downloaded, "the latest release installs");
  check(latest.exe === path.join(dir, name, "zig-analyzer") && (fs.statSync(latest.exe).mode & 0o111) !== 0, "its executable is in the install directory");
  check(fs.readFileSync(path.join(dir, "current"), "utf8") === name + "\n", "it is the current install");
  check(installer.installed(dir)?.exe === latest.exe, "the install is found");
  check(fs.readFileSync(path.join(dir, name, "README.md"), "utf8") === "fake release\n", "the whole archive is unpacked");
  check(
    server.requests.includes(`/download/v9.9.9/${name}.tar.gz`) && !server.requests.some((r) => r.startsWith("/latest/download/zig-analyzer-")),
    "the archive comes from the signed tag, not from latest",
  );

  const fast = await installer.install(dir, { version: "v9.9.8", optimize: "ReleaseFast" }, source, progress);
  check(fast.release === `zig-analyzer-v9.9.8-${target}-ReleaseFast` && installer.installed(dir)?.release === fast.release, "a given release and mode install");
  check(fs.existsSync(path.join(dir, name)), "the previous release stays until it is removed");
  await installer.removeOthers(dir, fast.release);
  check(!fs.existsSync(path.join(dir, name)) && fs.existsSync(fast.exe), "removeOthers removes the other releases");

  fs.rmSync(path.join(releases, "download", "v9.9.8", `${fast.release}.tar.gz`));
  const again = await installer.install(dir, { version: "v9.9.8", optimize: "ReleaseFast" }, source, progress);
  check(!again.downloaded && again.exe === fast.exe, "reinstalling the installed release needs no download");
  check(!leftovers(), "installs leave no temporary directory");
  await server.close();
}

function inspectionViews(): void {
  const format: views.Format = { path: (p) => p.replace(/^\/p\//, ""), time: () => "T" };
  const tree = views.render("syntaxTree", 'source_file@0..9\n  identifier@0..3 "abc"\n  error_node@4..9\nerror@4: expected expression\n', format);
  check(tree.lines[1] === '  identifier@0..3 "abc"' && JSON.stringify(tree.targets.get(1)) === '{"range":[0,3]}', "syntax tree: a token line leads to its range");
  check(tree.styles.some((s) => s.line === 2 && s.style === "error") && JSON.stringify(tree.targets.get(3)) === '{"range":[4,4]}', "syntax tree: errors");

  const graph = views.render("moduleGraph", {
    std_root: "/p/std/std.zig",
    modules: [
      { root: "/p/main.zig", builtin: "/p/builtin.zig", imports: [{ name: "std", module: 4294967295 }, { name: "lib", module: 1 }], files: 2 },
      { root: "/p/lib.zig", imports: [], files: 1 },
    ],
  }, format);
  check(graph.lines.join("\n") === [
    "std  std/std.zig", "", "[0] main.zig  2 files", "    builtin builtin.zig", "    import lib → [1] lib.zig", "    import std → std", "", "[1] lib.zig  1 file",
  ].join("\n"), "module graph: modules with their builtin and sorted imports");
  check(JSON.stringify(graph.targets.get(4)) === '{"line":7}' && JSON.stringify(graph.targets.get(5)) === '{"file":"/p/std/std.zig"}', "module graph: an import leads to its module");

  const file = views.render("fileStatus", {
    path: "/p/main.zig", origin: "user", context: "project", open: true, modules: ["/p/main.zig", "std"],
    projects: [{ root: "/p", last_build: { at_ms: 0, files: 1, diagnostics: 2 } }], single_file_roots: [],
  }, format);
  check(file.lines.join("\n") === [
    "File               main.zig", "Origin             user", "Context            project", "Open               yes",
    "Modules            main.zig", "                   std", "Projects           /p  last build T: 1 files, 2 diagnostics", "Single-file roots  none",
  ].join("\n"), "file status: aligned fields");

  const q = (name: string, total: number) => ({ name, executions: 1, hits: 0, cutoffs: 0, total_ms: total, self_ms: 0, max_ms: 0, memos: 0, keys: 0, bytes: 2048, deps: 0, incomplete: 0 });
  const status = views.render("status", {
    revision: 1, files: 2, deep_verifications: 0, writes: 0, max_rss_kb: 1024, intern_pool_items: 0, intern_pool_bytes: 0, heap_bytes: 0,
    allocator: null, queries: [q("a", 1), q("b", 5)],
  }, format);
  const rows = status.lines.filter((l) => /^ {2}[ab] /.test(l));
  check(status.lines[0] === "Revision            1" && status.lines.includes("Max RSS             1.0 MiB") && rows[0].startsWith("  b ") && rows[0].includes("2.0 KiB"),
    "status: fields, sizes, and queries by total time");

  const index = new views.ByteIndex("aé\r\n𝄞x\n");
  check(JSON.stringify(index.position(3)) === '{"line":0,"character":2}' && JSON.stringify(index.position(9)) === '{"line":1,"character":2}'
    && JSON.stringify(index.position(11)) === '{"line":2,"character":0}', "byte offsets to UTF-16 positions");
}

async function main(): Promise<void> {
  try {
    inspectionViews();
    blake2b();
    await signatures();
    await archives();
    await installs();
  } catch (err) {
    check(false, `unexpected error: ${err instanceof Error ? err.stack : String(err)}`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  console.log(results.join("\n"));
  if (failures > 0) {
    console.error(`${failures} checks failed`);
    process.exit(1);
  }
  console.log("all unit checks passed");
}

void main();
