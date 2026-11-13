// Verification of minisign signatures (https://jedisct1.github.io/minisign/), which sign the
// releases. Ed25519 comes from Node's crypto; BLAKE2b-512, which signatures of the `ED` algorithm
// sign the hash of, does not: Electron's BoringSSL has no BLAKE2b-512, so it is implemented here.
import * as crypto from "node:crypto";

const MASK = (1n << 64n) - 1n;
const IV = [
  0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
  0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n,
];
const SIGMA = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
  [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
  [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
  [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
  [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
  [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
  [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
  [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
];

const rotr = (x: bigint, n: bigint): bigint => ((x >> n) | (x << (64n - n))) & MASK;

function mix(v: bigint[], a: number, b: number, c: number, d: number, x: bigint, y: bigint): void {
  v[a] = (v[a] + v[b] + x) & MASK;
  v[d] = rotr(v[d] ^ v[a], 32n);
  v[c] = (v[c] + v[d]) & MASK;
  v[b] = rotr(v[b] ^ v[c], 24n);
  v[a] = (v[a] + v[b] + y) & MASK;
  v[d] = rotr(v[d] ^ v[a], 16n);
  v[c] = (v[c] + v[d]) & MASK;
  v[b] = rotr(v[b] ^ v[c], 63n);
}

function compress(h: bigint[], block: Buffer, t: bigint, last: boolean): void {
  const m: bigint[] = [];
  for (let i = 0; i < 16; i++) m.push(block.readBigUInt64LE(i * 8));
  const v = [...h, ...IV];
  v[12] ^= t & MASK;
  v[13] ^= t >> 64n;
  if (last) v[14] ^= MASK;
  for (let r = 0; r < 12; r++) {
    const s = SIGMA[r % 10];
    mix(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
    mix(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
    mix(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
    mix(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
    mix(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
    mix(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
    mix(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
    mix(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
  }
  for (let i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
}

/** BLAKE2b with a 64-byte digest and no key (RFC 7693) */
export function blake2b512(data: Uint8Array): Buffer {
  const h = [...IV];
  h[0] ^= 0x01010040n;
  const input = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  const blocks = Math.max(1, Math.ceil(input.length / 128));
  for (let i = 0; i < blocks; i++) {
    const last = i === blocks - 1;
    const block = Buffer.alloc(128);
    input.copy(block, 0, i * 128, Math.min(input.length, (i + 1) * 128));
    compress(h, block, BigInt(last ? input.length : (i + 1) * 128), last);
  }
  const out = Buffer.alloc(64);
  h.forEach((x, i) => out.writeBigUInt64LE(x, i * 8));
  return out;
}

/** The DER prefix of an Ed25519 SubjectPublicKeyInfo, which the 32 bytes of the key follow */
const ed25519Spki = Buffer.from("302a300506032b6570032100", "hex");

export interface PublicKey {
  keyId: Buffer;
  key: crypto.KeyObject;
}

/** A minisign public key: the base64 line of a `minisign.pub` */
export function publicKey(base64: string): PublicKey {
  const raw = Buffer.from(base64.trim(), "base64");
  if (raw.length !== 42 || raw.subarray(0, 2).toString("latin1") !== "Ed") {
    throw new Error("not a minisign public key");
  }
  return {
    keyId: raw.subarray(2, 10),
    key: crypto.createPublicKey({ key: Buffer.concat([ed25519Spki, raw.subarray(10)]), format: "der", type: "spki" }),
  };
}

/**
 * Checks the minisign signature `signature` (the text of a `.minisig` file) of `message` with
 * `key`: the key id, the Ed25519 signature of the BLAKE2b-512 hash of the message (algorithm `ED`,
 * the only one accepted), and the signature of the trusted comment. Returns the trusted comment;
 * throws when anything does not verify.
 */
export function verify(message: Uint8Array, signature: string, key: PublicKey): string {
  const lines = signature.split("\n").map((l) => l.replace(/\r$/, ""));
  const trusted = "trusted comment: ";
  if (!lines[0]?.startsWith("untrusted comment:") || !lines[2]?.startsWith(trusted)) {
    throw new Error("not a minisign signature");
  }
  const sig = Buffer.from(lines[1] ?? "", "base64");
  const global = Buffer.from(lines[3] ?? "", "base64");
  if (sig.length !== 74 || global.length !== 64) throw new Error("not a minisign signature");
  if (sig.subarray(0, 2).toString("latin1") !== "ED") throw new Error("the signature is not of a prehashed message");
  if (!sig.subarray(2, 10).equals(key.keyId)) throw new Error("the signature is by another key");
  const ed = sig.subarray(10);
  if (!crypto.verify(null, blake2b512(message), key.key, ed)) throw new Error("the signature does not verify");
  const comment = lines[2].slice(trusted.length);
  if (!crypto.verify(null, Buffer.concat([ed, Buffer.from(comment, "utf8")]), key.key, global)) {
    throw new Error("the signature of the trusted comment does not verify");
  }
  return comment;
}
