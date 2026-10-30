// OpenArch's share relay (docs/sharing.md): keeps one signed, encrypted
// envelope per share ID. It cannot read a share (the key is only in the
// link) and cannot change one (only the owner's Ed25519 key signs). No
// accounts, no cookies, and request bodies are never logged.

const TTL = 400 * 24 * 60 * 60;
const MAX_BODY = 256 * 1024;
const ID = /^[A-Za-z0-9_-]{22}$/;
const B64U = /^[A-Za-z0-9_-]+$/;
const encoder = new TextEncoder();

/// The relay's storage, over a Cloudflare KV namespace. A record is either
/// {envelope} or {ended: true, version}, a marker that the owner ended the
/// share (so an old upload, replayed, cannot bring it back).
export function kvStorage(kv) {
  return {
    get: (id) => kv.get(`share:${id}`, "json"),
    put: (id, record) => kv.put(`share:${id}`, JSON.stringify(record), { expirationTtl: TTL }),
  };
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, If-None-Match",
  "Access-Control-Expose-Headers": "ETag",
  "Access-Control-Max-Age": "86400",
};

function respond(status, body, headers = {}) {
  const all = { ...CORS, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...headers };
  if (body === null || status === 204 || status === 304) return new Response(null, { status, headers: all });
  if (typeof body === "string") {
    return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", ...all } });
  }
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8", ...all } });
}

const error = (status, message) => respond(status, { error: message });

function b64uDecode(text, length) {
  if (typeof text !== "string" || !B64U.test(text) || text.length % 4 === 1) return null;
  const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
  if (length !== undefined && binary.length !== length) return null;
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function b64uEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const isVersion = (value) => Number.isSafeInteger(value) && value >= 1;

async function idFor(publicKey) {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", publicKey));
  return b64uEncode(hash.subarray(0, 16));
}

async function verify(publicKey, signature, message) {
  try {
    const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signature, encoder.encode(message));
  } catch {
    return false;
  }
}

/// The body as JSON, or a Response: 413 past 256 KiB (by Content-Length
/// before reading, and by what actually arrives), 400 if it is not JSON.
async function readJSON(request) {
  const declared = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declared) && declared > MAX_BODY) return error(413, "larger than 256 KiB");
  const chunks = [];
  let size = 0;
  if (request.body) {
    const reader = request.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY) {
        await reader.cancel().catch(() => {});
        return error(413, "larger than 256 KiB");
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    return value && typeof value === "object" && !Array.isArray(value) ? value : error(400, "not a JSON object");
  } catch {
    return error(400, "not JSON");
  }
}

/// If-None-Match: "3", W/"3", a list of them, or *.
function matches(ifNoneMatch, version) {
  if (!ifNoneMatch) return false;
  return ifNoneMatch.split(",").some((tag) => {
    const text = tag.trim();
    return text === "*" || text.replace(/^W\//, "") === `"${version}"`;
  });
}

async function get(storage, id, request) {
  const record = await storage.get(id);
  if (!record) return error(404, "no such share");
  if (record.ended) return error(410, "sharing has ended");
  const { envelope } = record;
  const etag = `"${envelope.version}"`;
  if (matches(request.headers.get("If-None-Match"), envelope.version)) return respond(304, null, { ETag: etag });
  return respond(200, envelope, { ETag: etag });
}

async function put(storage, id, request) {
  const body = await readJSON(request);
  if (body instanceof Response) return body;
  const { v, pk, version, blob, sig } = body;
  const publicKey = b64uDecode(pk, 32);
  const signature = b64uDecode(sig, 64);
  const blobBytes = b64uDecode(blob);
  if (v !== 1 || !isVersion(version) || !publicKey || !signature || !blobBytes || blobBytes.length < 28) {
    return error(400, "malformed envelope");
  }
  if (await idFor(publicKey) !== id) return error(403, "the share ID is not this key's");
  if (!(await verify(publicKey, signature, `openarch-share-v1 put ${id} ${version} ${blob}`))) {
    return error(403, "bad signature");
  }
  const record = await storage.get(id);
  if (record?.ended) return error(410, "sharing has ended");
  const current = record?.envelope?.version ?? 0;
  if (version <= current) return error(409, `version must be higher than ${current}`);
  // Only the known fields are kept.
  await storage.put(id, { envelope: { v: 1, pk, version, blob, sig } });
  return respond(200, { version });
}

async function remove(storage, id, request) {
  const body = await readJSON(request);
  if (body instanceof Response) return body;
  const { version, sig } = body;
  const signature = b64uDecode(sig, 64);
  if (!isVersion(version) || !signature) return error(400, "malformed request");
  const record = await storage.get(id);
  if (!record) return error(404, "no such share");
  if (record.ended) return error(410, "sharing has ended");
  const publicKey = b64uDecode(record.envelope.pk, 32);
  if (!(await verify(publicKey, signature, `openarch-share-v1 delete ${id} ${version}`))) {
    return error(403, "bad signature");
  }
  if (version <= record.envelope.version) return error(409, `version must be higher than ${record.envelope.version}`);
  await storage.put(id, { ended: true, version });
  return respond(200, { version });
}

export async function handle(request, storage) {
  const { pathname } = new URL(request.url);
  if (request.method === "OPTIONS") return respond(204, null);
  if (pathname === "/") {
    return request.method === "GET" ? respond(200, "OpenArch share relay\n") : error(405, "method not allowed");
  }
  const match = /^\/v1\/shares\/([^/]+)$/.exec(pathname);
  if (!match) return error(404, "not found");
  const id = match[1];
  if (!ID.test(id)) return error(400, "malformed share ID");
  switch (request.method) {
    case "GET": return get(storage, id, request);
    case "PUT": return put(storage, id, request);
    case "DELETE": return remove(storage, id, request);
    default: return respond(405, { error: "method not allowed" }, { Allow: "GET, PUT, DELETE, OPTIONS" });
  }
}
