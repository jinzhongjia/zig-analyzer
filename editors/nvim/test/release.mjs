// Signs fake releases for test/install.lua, as the release workflow does (zig-minisign: a BLAKE2b
// prehashed Ed25519 signature of SHA256SUMS, trusted comment `zig-analyzer <tag>`):
//   node release.mjs key <key.pem>                    writes a key, prints the minisign public key
//   node release.mjs sign <key.pem> <dir> <comment>   writes <dir>/SHA256SUMS and its signature
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [cmd, keyFile, dir, comment] = process.argv.slice(2);

function load() {
  const privateKey = crypto.createPrivateKey(fs.readFileSync(keyFile));
  const raw = crypto.createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32);
  // The key id: the first 8 bytes of the SHA-256 of the public key
  const id = crypto.createHash('sha256').update(raw).digest().subarray(0, 8);
  return { privateKey, raw, id };
}

if (cmd === 'key') {
  const { privateKey } = crypto.generateKeyPairSync('ed25519');
  fs.writeFileSync(keyFile, privateKey.export({ format: 'pem', type: 'pkcs8' }));
  const { raw, id } = load();
  process.stdout.write(Buffer.concat([Buffer.from('Ed'), id, raw]).toString('base64'));
} else if (cmd === 'sign') {
  const { privateKey, id } = load();
  const files = fs.readdirSync(dir).filter((f) => !f.startsWith('SHA256SUMS')).sort();
  const sums = files
    .map((f) => `${crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, f))).digest('hex')}  ${f}\n`)
    .join('');
  fs.writeFileSync(path.join(dir, 'SHA256SUMS'), sums);
  const sig = crypto.sign(null, crypto.createHash('blake2b512').update(sums).digest(), privateKey);
  const global = crypto.sign(null, Buffer.concat([sig, Buffer.from(comment)]), privateKey);
  fs.writeFileSync(
    path.join(dir, 'SHA256SUMS.minisig'),
    'untrusted comment: test signature\n' +
      Buffer.concat([Buffer.from('ED'), id, sig]).toString('base64') +
      `\ntrusted comment: ${comment}\n` +
      global.toString('base64') +
      '\n',
  );
} else {
  process.stderr.write('usage: release.mjs key <key.pem> | sign <key.pem> <dir> <comment>\n');
  process.exit(2);
}
