// Tests of the release Worker: node updates/test/worker.test.mjs
import assert from "node:assert/strict";
import worker from "../src/index.mjs";

const sums = "0123456789abcdef  zig-analyzer-v0.1.2-x86_64-linux-ReleaseSafe.tar.gz\n";
const archive = "archive bytes";

function object(text) {
  return {
    body: new Blob([text]).stream(),
    size: Buffer.byteLength(text),
    httpEtag: '"test"',
    text: async () => text,
  };
}

function bucket(objects) {
  const map = new Map(Object.entries(objects));
  return {
    async get(key) {
      return map.get(key) ?? null;
    },
    async head(key) {
      const found = map.get(key);
      return found === undefined ? null : { ...found, body: undefined };
    },
  };
}

const env = {
  RELEASES: bucket({
    "metadata.json": object(JSON.stringify({ schema: 1, latest: "v0.1.2", versions: [] })),
    "releases/v0.1.2/SHA256SUMS": object(sums),
    "releases/v0.1.2/zig-analyzer-v0.1.2-x86_64-linux-ReleaseSafe.tar.gz": object(archive),
  }),
};

function check(name, f) {
  return f().then(
    () => console.log(`ok   ${name}`),
    (err) => {
      console.error(`FAIL ${name}`);
      throw err;
    },
  );
}

async function main() {
  await check("metadata.json is served", async () => {
    const response = await worker.fetch(new Request("https://releases.test/metadata.json"), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/json");
    assert.equal(response.headers.get("cache-control"), "public, max-age=300");
    assert.equal(response.headers.get("access-control-allow-origin"), "*");
    assert.deepEqual(JSON.parse(await response.text()), { schema: 1, latest: "v0.1.2", versions: [] });
  });

  await check("HEAD metadata.json has no body", async () => {
    const response = await worker.fetch(new Request("https://releases.test/metadata.json", { method: "HEAD" }), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-length"), String(Buffer.byteLength(JSON.stringify({ schema: 1, latest: "v0.1.2", versions: [] }))));
    assert.equal(await response.text(), "");
  });

  await check("latest/download redirects to the latest tag", async () => {
    const response = await worker.fetch(new Request("https://releases.test/latest/download/SHA256SUMS"), env);
    assert.equal(response.status, 302);
    assert.equal(response.headers.get("location"), "/download/v0.1.2/SHA256SUMS");
  });

  await check("a tag-specific file is served", async () => {
    const response = await worker.fetch(new Request("https://releases.test/download/v0.1.2/SHA256SUMS"), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "text/plain; charset=utf-8");
    assert.equal(response.headers.get("cache-control"), "public, max-age=31536000, immutable");
    assert.equal(await response.text(), sums);
  });

  await check("an archive has its content type", async () => {
    const response = await worker.fetch(
      new Request("https://releases.test/download/v0.1.2/zig-analyzer-v0.1.2-x86_64-linux-ReleaseSafe.tar.gz"),
      env,
    );
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/gzip");
    assert.equal(await response.text(), archive);
  });

  await check("missing objects are 404", async () => {
    const response = await worker.fetch(new Request("https://releases.test/download/v0.1.2/missing"), env);
    assert.equal(response.status, 404);
  });

  await check("another tag and path are 404", async () => {
    for (const url of [
      "https://releases.test/download/nightly/SHA256SUMS",
      "https://releases.test/download/v0.1.2/../SHA256SUMS",
      "https://releases.test/metadata.json/x",
      "https://releases.test/",
    ]) {
      const response = await worker.fetch(new Request(url), env);
      assert.equal(response.status, 404, url);
    }
  });

  await check("another method is 405", async () => {
    const response = await worker.fetch(new Request("https://releases.test/metadata.json", { method: "POST" }), env);
    assert.equal(response.status, 405);
  });

  await check("without metadata latest/download is 503", async () => {
    const empty = { RELEASES: bucket({}) };
    const response = await worker.fetch(new Request("https://releases.test/latest/download/SHA256SUMS"), empty);
    assert.equal(response.status, 503);
  });

  await check("invalid metadata is 503", async () => {
    const broken = { RELEASES: bucket({ "metadata.json": object('{"schema":1,"latest":"nightly"}') }) };
    const response = await worker.fetch(new Request("https://releases.test/latest/download/SHA256SUMS"), broken);
    assert.equal(response.status, 503);
  });

  console.log("all worker checks passed");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
