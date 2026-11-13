// Unpacking of the release archives without external tools: `.tar.gz` (ustar and GNU tar, with
// GNU long names and pax headers) and `.zip` (stored or deflated entries). Only directories and
// regular files below the one top-level directory `root` are accepted; anything else (links,
// absolute paths, `..`, entries outside `root`) makes the unpacking fail.
import * as fs from "node:fs";
import * as path from "node:path";
import { promisify } from "node:util";
import * as zlib from "node:zlib";

const gunzip = promisify(zlib.gunzip);
const inflateRaw = promisify(zlib.inflateRaw);

export interface Entry {
  /** Path relative to the archive root, `/`-separated; directories end with `/` */
  name: string;
  /** Unix permission bits, when the archive has them */
  mode?: number;
  data?: Buffer;
}

/** Checks that `name` is a relative path below `root/` and returns it */
function checkName(name: string, root: string): string {
  const dir = name.endsWith("/");
  const parts = (dir ? name.slice(0, -1) : name).split("/");
  if (name.includes("\\") || name.includes("\0") || parts.some((p) => p === "" || p === "." || p === "..")) {
    throw new Error(`the archive has an entry with an invalid path: ${JSON.stringify(name)}`);
  }
  if (parts[0] !== root) throw new Error(`the archive has an entry outside ${root}/: ${JSON.stringify(name)}`);
  return name;
}

function field(header: Buffer, start: number, length: number): string {
  const raw = header.subarray(start, start + length);
  const end = raw.indexOf(0);
  return raw.subarray(0, end < 0 ? raw.length : end).toString("utf8");
}

function octal(header: Buffer, start: number, length: number): number {
  const raw = header.subarray(start, start + length);
  // GNU base-256 for values that do not fit in octal
  if (raw[0] & 0x80) {
    let n = raw[0] & 0x7f;
    for (let i = 1; i < raw.length; i++) n = n * 256 + raw[i];
    return n;
  }
  const text = field(header, start, length).trim();
  if (!/^[0-7]*$/.test(text)) throw new Error("the archive has a damaged tar header");
  return text === "" ? 0 : parseInt(text, 8);
}

/** The `path` record of a pax extended header */
function paxPath(data: Buffer): string | undefined {
  let found: string | undefined;
  let i = 0;
  while (i < data.length) {
    const space = data.indexOf(0x20, i);
    const length = parseInt(data.subarray(i, space).toString("latin1"), 10);
    if (space < 0 || !(length > 0) || i + length > data.length) throw new Error("the archive has a damaged pax header");
    const record = data.subarray(space + 1, i + length - 1).toString("utf8");
    const eq = record.indexOf("=");
    if (record.slice(0, eq) === "path") found = record.slice(eq + 1);
    i += length;
  }
  return found;
}

/** The entries of the tar archive `tar` */
export function tarEntries(tar: Buffer, root: string): Entry[] {
  const entries: Entry[] = [];
  let longName: string | undefined;
  let offset = 0;
  for (;;) {
    if (offset + 512 > tar.length) throw new Error("the tar archive ends early");
    const header = tar.subarray(offset, offset + 512);
    if (header.every((b) => b === 0)) break;
    // The checksum sums the bytes as unsigned numbers; some old tars summed them as signed ones
    let sum = 0;
    let signed = 0;
    for (let i = 0; i < 512; i++) {
      const b = i >= 148 && i < 156 ? 0x20 : header[i];
      sum += b;
      signed += b > 127 ? b - 256 : b;
    }
    const checksum = octal(header, 148, 8);
    if (checksum !== sum && checksum !== signed) throw new Error("the archive has a damaged tar header");
    const size = octal(header, 124, 12);
    const type = String.fromCharCode(header[156]);
    const start = offset + 512;
    if (start + size > tar.length) throw new Error("the tar archive ends early");
    const data = tar.subarray(start, start + size);
    offset = start + Math.ceil(size / 512) * 512;
    if (type === "L") {
      longName = field(data, 0, data.length);
      continue;
    }
    if (type === "x") {
      longName = paxPath(data) ?? longName;
      continue;
    }
    if (type === "g") continue;
    let name = field(header, 0, 100);
    const magic = header.subarray(257, 263).toString("latin1");
    if (magic === "ustar\0") {
      const prefix = field(header, 345, 155);
      if (prefix) name = `${prefix}/${name}`;
    }
    if (longName !== undefined) name = longName;
    longName = undefined;
    const mode = octal(header, 100, 8) & 0o777;
    if (type === "5") {
      entries.push({ name: checkName(name.endsWith("/") ? name : name + "/", root), mode });
    } else if (type === "0" || type === "\0" || type === "7") {
      entries.push({ name: checkName(name, root), mode, data });
    } else {
      throw new Error(`the archive has an entry that is no file or directory: ${JSON.stringify(name)}`);
    }
  }
  return entries;
}

const crcTable = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

/** CRC-32 of zip entries (zlib.crc32 is newer than the Node of VS Code 1.91) */
export function crc32(data: Buffer): number {
  let c = -1;
  for (let i = 0; i < data.length; i++) c = crcTable[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

/** The entries of the zip archive `zip` */
export async function zipEntries(zip: Buffer, root: string): Promise<Entry[]> {
  // The end of central directory record is in the last 22 + 65535 bytes (its comment)
  let eocd = -1;
  for (let i = zip.length - 22; i >= Math.max(0, zip.length - 22 - 0xffff); i--) {
    if (zip.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error("the archive is not a zip archive");
  const count = zip.readUInt16LE(eocd + 10);
  let offset = zip.readUInt32LE(eocd + 16);
  if (count === 0xffff || offset === 0xffffffff) throw new Error("the zip archive needs ZIP64, which is not supported");
  const entries: Entry[] = [];
  for (let n = 0; n < count; n++) {
    if (offset + 46 > zip.length || zip.readUInt32LE(offset) !== 0x02014b50) throw new Error("the zip archive is damaged");
    const madeBy = zip.readUInt16LE(offset + 4);
    const flags = zip.readUInt16LE(offset + 8);
    const method = zip.readUInt16LE(offset + 10);
    const crc = zip.readUInt32LE(offset + 16);
    const compressed = zip.readUInt32LE(offset + 20);
    const size = zip.readUInt32LE(offset + 24);
    const nameLength = zip.readUInt16LE(offset + 28);
    const extraLength = zip.readUInt16LE(offset + 30);
    const commentLength = zip.readUInt16LE(offset + 32);
    const external = zip.readUInt32LE(offset + 38);
    const local = zip.readUInt32LE(offset + 42);
    const name = zip.subarray(offset + 46, offset + 46 + nameLength).toString(flags & 0x800 ? "utf8" : "latin1");
    offset += 46 + nameLength + extraLength + commentLength;
    if (flags & 0x1) throw new Error(`the zip archive has an encrypted entry: ${JSON.stringify(name)}`);
    if (compressed === 0xffffffff || size === 0xffffffff || local === 0xffffffff) {
      throw new Error("the zip archive needs ZIP64, which is not supported");
    }
    // Unix permission bits, when the archive was made on Unix
    const unixMode = madeBy >> 8 === 3 ? (external >>> 16) & 0o170777 : undefined;
    if (unixMode !== undefined && (unixMode & 0o170000) !== 0 && ![0o040000, 0o100000].includes(unixMode & 0o170000)) {
      throw new Error(`the archive has an entry that is no file or directory: ${JSON.stringify(name)}`);
    }
    const mode = unixMode === undefined ? undefined : unixMode & 0o777;
    if (name.endsWith("/")) {
      entries.push({ name: checkName(name, root), mode });
      continue;
    }
    if (local + 30 > zip.length || zip.readUInt32LE(local) !== 0x04034b50) throw new Error("the zip archive is damaged");
    const dataStart = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
    if (dataStart + compressed > zip.length) throw new Error("the zip archive is damaged");
    const raw = zip.subarray(dataStart, dataStart + compressed);
    let data: Buffer;
    if (method === 0) data = raw;
    else if (method === 8) data = await inflateRaw(raw);
    else throw new Error(`the zip archive has an entry compressed with method ${method}, which is not supported`);
    if (data.length !== size || crc32(data) !== crc) throw new Error(`the zip archive has a damaged entry: ${JSON.stringify(name)}`);
    entries.push({ name: checkName(name, root), mode, data });
  }
  return entries;
}

/**
 * Unpacks `archive`, a `.zip` archive when `zip` holds, else a `.tar.gz` archive, whose entries
 * must all be below the directory `root`, into the directory `dest`: `dest/root/...`.
 */
export async function unpack(archive: Buffer, zip: boolean, root: string, dest: string): Promise<void> {
  const entries = zip ? await zipEntries(archive, root) : tarEntries(await gunzip(archive), root);
  for (const e of entries) {
    const target = path.join(dest, ...e.name.split("/"));
    if (e.data === undefined) {
      await fs.promises.mkdir(target, { recursive: true });
    } else {
      await fs.promises.mkdir(path.dirname(target), { recursive: true });
      await fs.promises.writeFile(target, e.data, { mode: e.mode || 0o644, flag: "wx" });
    }
  }
}
