// Serves the Web export files that are over the Pages limit from R2
// (binding DEMO_BLOBS). _routes.json, written by prepare_r2_assets.mjs,
// sends only those paths here; the key is the path ("demo/index.wasm").
const CONTENT_TYPES = {
  ".pck": "application/octet-stream",
  ".wasm": "application/wasm",
};

function assetKey(context) {
  const segments = Array.isArray(context.params.path) ? context.params.path : [context.params.path];
  const path = segments.filter(Boolean).join("/");
  if (!path || path.includes("..")) return null;
  const dot = path.lastIndexOf(".");
  const suffix = dot === -1 ? "" : path.slice(dot).toLowerCase();
  return CONTENT_TYPES[suffix] ? path : null;
}

function responseHeaders(object, key) {
  const suffix = key.slice(key.lastIndexOf(".")).toLowerCase();
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("Content-Type", CONTENT_TYPES[suffix]);
  headers.set("Cache-Control", "public, max-age=0, must-revalidate");
  headers.set("ETag", object.httpEtag);
  headers.set("Accept-Ranges", "bytes");
  headers.set("X-Content-Type-Options", "nosniff");
  return headers;
}

export async function onRequestGet(context) {
  const key = assetKey(context);
  if (key === null) return context.next();
  const object = await context.env.DEMO_BLOBS.get(key, {
    onlyIf: context.request.headers,
    range: context.request.headers,
  });
  if (object === null) return context.next();
  if (!object.body) {
    return new Response(null, { status: 304, headers: { ETag: object.httpEtag } });
  }
  const headers = responseHeaders(object, key);
  const isRangeRequest = context.request.headers.has("Range");
  if (isRangeRequest && object.range && "offset" in object.range) {
    const end = object.range.offset + object.range.length - 1;
    headers.set("Content-Range", `bytes ${object.range.offset}-${end}/${object.size}`);
  }
  return new Response(object.body, { headers, status: isRangeRequest ? 206 : 200 });
}

export async function onRequestHead(context) {
  const key = assetKey(context);
  if (key === null) return context.next();
  const object = await context.env.DEMO_BLOBS.head(key);
  if (object === null) return context.next();
  const headers = responseHeaders(object, key);
  headers.set("Content-Length", String(object.size));
  return new Response(null, { headers });
}
