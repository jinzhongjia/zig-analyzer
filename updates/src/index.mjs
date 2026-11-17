// The release server: metadata.json and the release artifacts are stored in R2 and served
// from releases.zig-analyzer.dev. The client verifies the release signature itself, so this
// Worker only handles availability and caching.
const tagPattern = /^v\d+\.\d+\.\d+[0-9A-Za-z.-]*$/;
const filePattern = /^[0-9A-Za-z._-]+$/;
const metadataKey = "metadata.json";

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return text(405, "method not allowed");
    }
    const path = new URL(request.url).pathname;

    if (path === "/metadata.json") {
      const object = await read(env.RELEASES, metadataKey, request.method);
      return objectResponse(request, object, "application/json", "public, max-age=300");
    }

    let match = /^\/latest\/download\/([^/]+)$/.exec(path);
    if (match) {
      const file = match[1];
      if (!filePattern.test(file)) return text(404, "not found");
      const latest = await latestTag(env.RELEASES);
      if (latest === undefined) return text(503, "no stable release");
      return new Response(null, {
        status: 302,
        headers: {
          Location: `/download/${latest}/${file}`,
          "Cache-Control": "public, max-age=300",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }

    match = /^\/download\/([^/]+)\/([^/]+)$/.exec(path);
    if (match) {
      const tag = match[1];
      const file = match[2];
      if (!tagPattern.test(tag) || !filePattern.test(file)) return text(404, "not found");
      const object = await read(env.RELEASES, `releases/${tag}/${file}`, request.method);
      return objectResponse(request, object, contentType(file), "public, max-age=31536000, immutable");
    }

    return text(404, "not found");
  },
};

async function read(bucket, key, method) {
  return method === "HEAD" ? bucket.head(key) : bucket.get(key);
}

async function latestTag(bucket) {
  const object = await bucket.get(metadataKey);
  if (!object) return undefined;
  try {
    const data = JSON.parse(await object.text());
    return typeof data.latest === "string" && tagPattern.test(data.latest) ? data.latest : undefined;
  } catch {
    return undefined;
  }
}

function objectResponse(request, object, type, cacheControl) {
  if (!object) return text(404, "not found");
  return new Response(request.method === "HEAD" ? null : object.body, {
    headers: {
      "Content-Type": type,
      "Content-Length": String(object.size),
      "Cache-Control": cacheControl,
      "Access-Control-Allow-Origin": "*",
      ETag: object.httpEtag,
    },
  });
}

function contentType(file) {
  if (file.endsWith(".tar.gz")) return "application/gzip";
  if (file.endsWith(".zip")) return "application/zip";
  if (file.endsWith(".json")) return "application/json";
  return "text/plain; charset=utf-8";
}

function text(status, body) {
  return new Response(`${body}\n`, {
    status,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
    },
  });
}
