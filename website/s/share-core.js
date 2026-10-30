// OpenArch's shared bookmarks, version 1 (docs/sharing.md): reading links
// and, for the tests, writing them. No dependencies; runs in browsers and in
// Node 22 (WebCrypto, CompressionStream). Nothing here talks to a server
// except fetchLive, and the key never goes into a request.

export const DEFAULT_RELAY = "https://share.openarch.app";
export const PBKDF2_ROUNDS = 600000;
export const LIMITS = {
  upload: 256 * 1024,
  payload: 4 * 1024 * 1024,
  nodes: 5000,
  depth: 16,
  title: 300,
};

/// code: invalid-link, unsupported, wrong-password, damaged, not-found,
/// ended, rollback, unreachable, server.
export class ShareError extends Error {
  constructor(code, message = code) {
    super(message);
    this.name = "ShareError";
    this.code = code;
  }
}

const subtle = globalThis.crypto.subtle;
const encoder = new TextEncoder();
const B64U = /^[A-Za-z0-9_-]*$/;
const ID = /^[A-Za-z0-9_-]{22}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COLOR = /^#[0-9a-f]{6}$/i;

// MARK: base64url

export function b64uEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// Strict: only the base64url alphabet, no padding, and only the one
/// spelling that encodes back to the same text.
export function b64uDecode(text) {
  if (typeof text !== "string" || !B64U.test(text) || text.length % 4 === 1) {
    throw new ShareError("invalid-link", "not base64url");
  }
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  if (b64uEncode(bytes) !== text) throw new ShareError("invalid-link", "not canonical base64url");
  return bytes;
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function randomBytes(count) {
  return globalThis.crypto.getRandomValues(new Uint8Array(count));
}

// MARK: Associated data

export const KEY_AAD = "openarch-share-v1 key";
export const SNAPSHOT_AAD = "openarch-share-v1 snapshot";
export function liveAAD(id, version) {
  return `openarch-share-v1 live ${id} ${version}`;
}
export function putMessage(id, version, blobText) {
  return `openarch-share-v1 put ${id} ${version} ${blobText}`;
}
export function deleteMessage(id, version) {
  return `openarch-share-v1 delete ${id} ${version}`;
}

// MARK: AES-256-GCM

/// nonce ‖ ciphertext ‖ tag.
export async function aesSeal(keyBytes, plaintext, aad, nonce = randomBytes(12)) {
  const key = await subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const sealed = await subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: encoder.encode(aad) }, key, plaintext);
  return concat(nonce, new Uint8Array(sealed));
}

export async function aesOpen(keyBytes, blob, aad, code = "damaged") {
  if (!(keyBytes instanceof Uint8Array) || keyBytes.length !== 32 || blob.length < 28) throw new ShareError(code);
  try {
    const key = await subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
    const plain = await subtle.decrypt(
      { name: "AES-GCM", iv: blob.subarray(0, 12), additionalData: encoder.encode(aad) }, key, blob.subarray(12));
    return new Uint8Array(plain);
  } catch {
    throw new ShareError(code);
  }
}

// MARK: Password

export async function derivePasswordKey(password, salt) {
  const material = await subtle.importKey("raw", encoder.encode(password.normalize("NFC")), "PBKDF2", false, ["deriveBits"]);
  const bits = await subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: PBKDF2_ROUNDS }, material, 256);
  return new Uint8Array(bits);
}

/// The password key slot: salt (16) ‖ nonce (12) ‖ wrapped key (32) ‖ tag (16).
export async function wrapPassword(key, password, { salt = randomBytes(16), nonce = randomBytes(12) } = {}) {
  const wrapKey = await derivePasswordKey(password, salt);
  return concat(salt, await aesSeal(wrapKey, key, KEY_AAD, nonce));
}

export async function unwrapPassword(slotBytes, password) {
  if (slotBytes.length !== 76) throw new ShareError("invalid-link");
  const wrapKey = await derivePasswordKey(password, slotBytes.subarray(0, 16));
  const key = await aesOpen(wrapKey, slotBytes.subarray(16), KEY_AAD, "wrong-password");
  if (key.length !== 32) throw new ShareError("wrong-password");
  return key;
}

// MARK: Link

function normalizedRelay(relay) {
  return relay ? relay.replace(/\/+$/, "") : null;
}

/// Relays are https, or http on this machine (for running one locally).
function checkRelay(text) {
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new ShareError("invalid-link", "relay is not a URL");
  }
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]";
  if (!(url.protocol === "https:" || (url.protocol === "http:" && local)) || url.username || url.password
      || url.search || url.hash) {
    throw new ShareError("invalid-link", "relay must be an https URL");
  }
  return normalizedRelay(url.href);
}

/// {mode: "live", id, keySlot, relay} or {mode: "snapshot", blob, keySlot,
/// relay: null}; keySlot is {type: "key" | "password", bytes}. Accepts the
/// fragment with or without "#".
export function parseFragment(fragment) {
  const text = String(fragment ?? "").replace(/^#/, "");
  const parts = text.split(".");
  if (parts.length < 4 || parts.length > 5) throw new ShareError("invalid-link");
  if (parts[0] !== "1") {
    throw new ShareError(/^[0-9]+$/.test(parts[0]) ? "unsupported" : "invalid-link");
  }
  const [, mode, locator, slot, relayPart] = parts;
  if (mode !== "l" && mode !== "s") throw new ShareError("invalid-link");

  const slotBytes = b64uDecode(slot.slice(1));
  let keySlot;
  if (slot[0] === "k" && slotBytes.length === 32) keySlot = { type: "key", bytes: slotBytes };
  else if (slot[0] === "p" && slotBytes.length === 76) keySlot = { type: "password", bytes: slotBytes };
  else throw new ShareError("invalid-link");

  let relay = null;
  if (relayPart !== undefined) {
    if (mode !== "l" || relayPart[0] !== "r") throw new ShareError("invalid-link");
    relay = checkRelay(new TextDecoder("utf-8", { fatal: true }).decode(b64uDecode(relayPart.slice(1))));
  }

  if (mode === "l") {
    if (!ID.test(locator)) throw new ShareError("invalid-link");
    b64uDecode(locator);
    return { mode: "live", id: locator, keySlot, relay };
  }
  const blob = b64uDecode(locator);
  if (blob.length < 28) throw new ShareError("invalid-link");
  return { mode: "snapshot", blob, keySlot, relay: null };
}

export function buildFragment({ mode, id, blob, keySlot, relay }) {
  const slot = (keySlot.type === "password" ? "p" : "k") + b64uEncode(keySlot.bytes);
  if (mode === "snapshot") return ["1", "s", b64uEncode(blob), slot].join(".");
  const parts = ["1", "l", id, slot];
  const base = normalizedRelay(relay);
  if (base && base !== DEFAULT_RELAY) parts.push("r" + b64uEncode(encoder.encode(base)));
  return parts.join(".");
}

// MARK: Payload

export async function encodePayload(payload, { compress = true } = {}) {
  const json = encoder.encode(JSON.stringify(payload));
  return compress ? concat(new Uint8Array([1]), await deflateRaw(json)) : concat(new Uint8Array([0]), json);
}

async function deflateRaw(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/// Inflates, but stops past the payload limit (a small blob can unpack to
/// gigabytes).
async function inflateRaw(bytes) {
  const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw")).getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > LIMITS.payload) {
        await reader.cancel().catch(() => {});
        throw new ShareError("damaged", "payload too large");
      }
      chunks.push(value);
    }
  } catch (error) {
    throw error instanceof ShareError ? error : new ShareError("damaged");
  }
  return concat(...chunks);
}

/// The plaintext's JSON: format byte 0 (as is) or 1 (raw DEFLATE).
export async function decodePayload(plaintext) {
  if (!plaintext.length) throw new ShareError("damaged");
  let json;
  if (plaintext[0] === 0) json = plaintext.subarray(1);
  else if (plaintext[0] === 1) json = await inflateRaw(plaintext.subarray(1));
  else throw new ShareError("unsupported");
  if (json.length > LIMITS.payload) throw new ShareError("damaged");
  let payload;
  try {
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(json));
  } catch {
    throw new ShareError("damaged");
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new ShareError("damaged");
  if (payload.v !== 1) throw new ShareError("unsupported");
  if ((payload.kind !== "folder" && payload.kind !== "space") || typeof payload.name !== "string"
      || !Array.isArray(payload.items)) {
    throw new ShareError("damaged");
  }
  return payload;
}

function trimTitle(value) {
  if (typeof value !== "string") return "";
  const characters = Array.from(value.trim());
  return characters.length > LIMITS.title ? characters.slice(0, LIMITS.title).join("") : characters.join("");
}

function webURL(value) {
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:" ? value : null;
  } catch {
    return null;
  }
}

/// What readers keep: http and https tabs, folders down to 16 levels, at most
/// 5000 entries, titles of at most 300 characters. Unknown keys go.
export function sanitize(payload) {
  let count = 0;
  const nodes = (list, depth) => {
    const out = [];
    if (!Array.isArray(list) || depth > LIMITS.depth) return out;
    for (const node of list) {
      if (count >= LIMITS.nodes) break;
      if (!node || typeof node !== "object" || typeof node.id !== "string" || !UUID.test(node.id)) continue;
      if (Array.isArray(node.children)) {
        count++;
        const folder = { id: node.id, title: trimTitle(node.title) };
        if (typeof node.icon === "string" && node.icon.length <= 64) folder.icon = node.icon;
        folder.children = nodes(node.children, depth + 1);
        out.push(folder);
      } else {
        const url = webURL(node.url);
        if (!url) continue;
        count++;
        out.push({ id: node.id, title: trimTitle(node.title), url });
      }
    }
    return out;
  };
  const clean = { v: 1, kind: payload.kind === "space" ? "space" : "folder", name: trimTitle(payload.name) };
  if (typeof payload.icon === "string" && payload.icon.length <= 64) clean.icon = payload.icon;
  if (typeof payload.color === "string" && COLOR.test(payload.color)) clean.color = payload.color;
  if (typeof payload.updated === "string" && !Number.isNaN(Date.parse(payload.updated))) clean.updated = payload.updated;
  clean.items = nodes(payload.items, 1);
  return clean;
}

// MARK: Reading

export async function openSnapshot(blob, key) {
  return sanitize(await decodePayload(await aesOpen(key, blob, SNAPSHOT_AAD)));
}

export async function shareIdFor(publicKey) {
  const hash = new Uint8Array(await subtle.digest("SHA-256", publicKey));
  return b64uEncode(hash.subarray(0, 16));
}

/// Checks an Ed25519 signature; true when the runtime cannot (older
/// browsers), since the content is authenticated by AES-GCM either way.
async function verifySignature(publicKey, signature, message) {
  let key;
  try {
    key = await subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
  } catch {
    console.warn("OpenArch: this browser cannot check Ed25519 signatures; relying on AES-GCM alone");
    return true;
  }
  return subtle.verify({ name: "Ed25519" }, key, signature, encoder.encode(message));
}

function isVersion(value) {
  return Number.isSafeInteger(value) && value >= 1;
}

/// The envelope's fields, checked: pk 32 bytes, sig 64 bytes, blob, version.
export function readEnvelope(envelope) {
  if (!envelope || typeof envelope !== "object" || envelope.v !== 1 || !isVersion(envelope.version)
      || typeof envelope.blob !== "string" || typeof envelope.pk !== "string" || typeof envelope.sig !== "string") {
    throw new ShareError("damaged");
  }
  try {
    const pk = b64uDecode(envelope.pk);
    const sig = b64uDecode(envelope.sig);
    const blob = b64uDecode(envelope.blob);
    if (pk.length !== 32 || sig.length !== 64 || blob.length < 28) throw new ShareError("damaged");
    return { pk, sig, blob, version: envelope.version, blobText: envelope.blob };
  } catch {
    throw new ShareError("damaged");
  }
}

/// Opens an envelope from the relay for |id|: the ID must be the public
/// key's hash, the signature must hold, and the version must not go back.
export async function openEnvelope(envelope, id, key, { lastVersion = 0 } = {}) {
  const { pk, sig, blob, version, blobText } = readEnvelope(envelope);
  if (await shareIdFor(pk) !== id) throw new ShareError("damaged", "share ID does not match its key");
  if (!(await verifySignature(pk, sig, putMessage(id, version, blobText)))) throw new ShareError("damaged", "bad signature");
  if (version < lastVersion) throw new ShareError("rollback");
  const payload = sanitize(await decodePayload(await aesOpen(key, blob, liveAAD(id, version))));
  return { payload, version };
}

/// The live share |id| from the relay: {payload, version}, or {notModified:
/// true, version} when it is still |lastVersion|.
export async function fetchLive(id, key, relayBase = DEFAULT_RELAY, { lastVersion = 0, fetch = globalThis.fetch } = {}) {
  if (!ID.test(id)) throw new ShareError("invalid-link");
  const headers = { Accept: "application/json" };
  if (lastVersion > 0) headers["If-None-Match"] = `"${lastVersion}"`;
  let response;
  try {
    response = await fetch(`${normalizedRelay(relayBase || DEFAULT_RELAY)}/v1/shares/${id}`, {
      headers, cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer",
    });
  } catch {
    throw new ShareError("unreachable");
  }
  if (response.status === 304 && lastVersion > 0) return { notModified: true, version: lastVersion };
  if (response.status === 404) throw new ShareError("not-found");
  if (response.status === 410) throw new ShareError("ended");
  if (response.status !== 200) throw new ShareError("server", `relay answered ${response.status}`);
  let envelope;
  try {
    envelope = await response.json();
  } catch {
    throw new ShareError("damaged");
  }
  return openEnvelope(envelope, id, key, { lastVersion });
}

/// Everything a link shows: {link, payload, version?}. |password| is needed
/// when the link's key slot is a password one.
export async function openLink(fragment, { password, lastVersion = 0, fetch } = {}) {
  const link = parseFragment(fragment);
  let key = link.keySlot.bytes;
  if (link.keySlot.type === "password") {
    if (!password) throw new ShareError("wrong-password", "password needed");
    key = await unwrapPassword(link.keySlot.bytes, password);
  }
  if (link.mode === "snapshot") return { link, payload: await openSnapshot(link.blob, key) };
  const result = await fetchLive(link.id, key, link.relay ?? DEFAULT_RELAY, { lastVersion, fetch });
  return { link, ...result };
}

// MARK: Writing (OpenArch's apps do this in Swift; here for the tests)

export function generateContentKey() {
  return randomBytes(32);
}

const PKCS8_ED25519 = new Uint8Array([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]);

/// {privateKey (CryptoKey), publicKey (32 bytes)} from a 32-byte seed, the
/// form CryptoKit's Curve25519.Signing.PrivateKey(rawRepresentation:) uses.
export async function importSigningSeed(seed) {
  const privateKey = await subtle.importKey("pkcs8", concat(PKCS8_ED25519, seed), { name: "Ed25519" }, true, ["sign"]);
  const jwk = await subtle.exportKey("jwk", privateKey);
  return { privateKey, publicKey: b64uDecode(jwk.x) };
}

export async function generateSigningKey() {
  return importSigningSeed(randomBytes(32));
}

export async function sign(privateKey, message) {
  return new Uint8Array(await subtle.sign({ name: "Ed25519" }, privateKey, encoder.encode(message)));
}

export async function sealPayload(payload, key, aad, { nonce, compress = true } = {}) {
  return aesSeal(key, await encodePayload(payload, { compress }), aad, nonce);
}

/// The envelope for uploading |payload| as |version| of the share whose
/// signing key is |signing| ({privateKey, publicKey}).
export async function makeEnvelope({ signing, version, payload, key, nonce }) {
  const id = await shareIdFor(signing.publicKey);
  const blob = b64uEncode(await sealPayload(payload, key, liveAAD(id, version), { nonce }));
  const sig = await sign(signing.privateKey, putMessage(id, version, blob));
  return { id, envelope: { v: 1, pk: b64uEncode(signing.publicKey), version, blob, sig: b64uEncode(sig) } };
}

/// The body of a DELETE that ends the share.
export async function makeDeletion({ signing, version }) {
  const id = await shareIdFor(signing.publicKey);
  return { id, body: { version, sig: b64uEncode(await sign(signing.privateKey, deleteMessage(id, version))) } };
}
