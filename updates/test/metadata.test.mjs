// Tests of metadata.json generation: node updates/test/metadata.test.mjs
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { artifacts, buildMetadata, compareTags, supportedZig } from "../metadata.mjs";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zig-analyzer-metadata-"));

function check(name, f) {
  try {
    f();
    console.log(`ok   ${name}`);
  } catch (err) {
    console.error(`FAIL ${name}`);
    throw err;
  }
}

function write(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}

check("supported_versions is read from ZigEnv.zig", () => {
  const source = 'pub const supported_versions = [_][]const u8{ "0.17.0", "0.17.1" };';
  assert.deepEqual(supportedZig(source), ["0.17.0", "0.17.1"]);
  assert.throws(() => supportedZig("pub const other = 1;"), /supported_versions/);
});

check("artifacts are read from the archive names", () => {
  const dir = path.join(tmp, "dist");
  for (const name of [
    "zig-analyzer-v0.1.2-x86_64-linux-ReleaseSafe.tar.gz",
    "zig-analyzer-v0.1.2-x86_64-linux-ReleaseFast.tar.gz",
    "zig-analyzer-v0.1.2-aarch64-macos-ReleaseSafe.zip",
    "zig-analyzer-v0.1.2-x86_64-macos-ReleaseSafe.tar.gz.minisig",
    "SHA256SUMS",
    "SHA256SUMS.minisig",
  ]) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, name), name);
  }
  const list = artifacts(dir, "v0.1.2");
  assert.equal(list.length, 3);
  assert.deepEqual(list.map((a) => `${a.target}/${a.optimize}`), [
    "aarch64-macos/ReleaseSafe",
    "x86_64-linux/ReleaseSafe",
    "x86_64-linux/ReleaseFast",
  ]);
  assert.ok(list.every((a) => a.size > 0 && a.file.startsWith("zig-analyzer-v0.1.2-")));
});

check("tags compare as SemVer", () => {
  assert.ok(compareTags("v0.2.0", "v0.1.10") > 0);
  assert.ok(compareTags("v0.1.2-rc.1", "v0.1.2") < 0);
  assert.equal(compareTags("v0.1.2+build", "v0.1.2"), 0);
  assert.ok(compareTags("v0.1.2-alpha.2", "v0.1.2-alpha.10") < 0);
});

check("versions are merged, sorted, and latest is the newest stable", () => {
  const old = {
    schema: 1,
    latest: "v0.1.1",
    versions: [{ tag: "v0.1.1", prerelease: false, released: "2026-11-13T00:00:00Z", zig: {}, artifacts: [] }],
  };
  let metadata = buildMetadata(old, {
    tag: "v0.1.2",
    prerelease: false,
    released: "2026-11-16T00:00:00Z",
    zig: {},
    artifacts: [],
  });
  assert.deepEqual(metadata.versions.map((v) => v.tag), ["v0.1.2", "v0.1.1"]);
  assert.equal(metadata.latest, "v0.1.2");

  metadata = buildMetadata(metadata, {
    tag: "v0.2.0-rc.1",
    prerelease: true,
    released: "2026-11-18T00:00:00Z",
    zig: {},
    artifacts: [],
  });
  assert.deepEqual(metadata.versions.map((v) => v.tag), ["v0.2.0-rc.1", "v0.1.2", "v0.1.1"]);
  assert.equal(metadata.latest, "v0.1.2");

  metadata = buildMetadata(metadata, {
    tag: "v0.2.0",
    prerelease: false,
    released: "2026-11-18T00:00:00Z",
    zig: {},
    artifacts: [],
  });
  assert.deepEqual(metadata.versions.map((v) => v.tag), ["v0.2.0", "v0.2.0-rc.1", "v0.1.2", "v0.1.1"]);
  assert.equal(metadata.latest, "v0.2.0");
});

check("a tag replaces its older entry", () => {
  const metadata = buildMetadata(
    {
      schema: 1,
      latest: "v0.1.2",
      versions: [{ tag: "v0.1.2", prerelease: false, released: "old", zig: {}, artifacts: [] }],
    },
    { tag: "v0.1.2", prerelease: false, released: "new", zig: {}, artifacts: [] },
  );
  assert.equal(metadata.versions.length, 1);
  assert.equal(metadata.versions[0].released, "new");
});

check("another schema is rejected instead of losing the versions", () => {
  assert.throws(() => buildMetadata({ schema: 2, versions: [] }, { tag: "v0.1.2", prerelease: false }), /schema/);
  assert.throws(() => buildMetadata({ schema: 1 }, { tag: "v0.1.2", prerelease: false }), /schema/);
});

check("the command writes metadata.json", () => {
  const dir = path.join(tmp, "cli");
  const dist = path.join(dir, "dist");
  write(path.join(dist, "zig-analyzer-v0.1.2-x86_64-linux-ReleaseSafe.tar.gz"), "archive");
  const supported = path.join(dir, "ZigEnv.zig");
  write(supported, 'pub const supported_versions = [_][]const u8{ "0.17.0", "0.17.1" };');
  const output = path.join(dir, "metadata.json");
  execFileSync(
    process.execPath,
    [
      path.join(root, "metadata.mjs"),
      "--tag", "v0.1.2",
      "--released", "2026-11-16T00:00:00Z",
      "--packaging-zig", "0.17.1",
      "--artifacts", dist,
      "--supported-source", supported,
      "--output", output,
      "--notes-base", "https://example.test/releases",
    ],
    { stdio: "inherit" },
  );
  const metadata = JSON.parse(fs.readFileSync(output, "utf8"));
  assert.equal(metadata.schema, 1);
  assert.equal(metadata.latest, "v0.1.2");
  assert.deepEqual(metadata.versions[0].zig, { supported: ["0.17.0", "0.17.1"], packaging: "0.17.1" });
  assert.equal(metadata.versions[0].artifacts[0].file, "zig-analyzer-v0.1.2-x86_64-linux-ReleaseSafe.tar.gz");
  assert.equal(metadata.versions[0].notes, "https://example.test/releases/v0.1.2");
});

fs.rmSync(tmp, { recursive: true, force: true });
console.log("all metadata checks passed");
