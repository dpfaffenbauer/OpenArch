import assert from "node:assert/strict";
import test from "node:test";
import {
  b64uEncode, generateContentKey, generateSigningKey, makeDeletion, makeEnvelope,
} from "../../website/s/share-core.js";
import { FakeKV, RELAY, json, relayFetch } from "./helpers.mjs";

const payload = (name) => ({
  v: 1, kind: "folder", name,
  items: [{ id: "6F1C2F8E-1D2B-4C1E-9A55-0B1C2D3E4F50", title: "Example", url: "https://example.com/" }],
});

async function setup() {
  const kv = new FakeKV();
  const fetch = relayFetch(kv);
  const signing = await generateSigningKey();
  const key = generateContentKey();
  const upload = async (version, overrides = {}) => {
    const { id, envelope } = await makeEnvelope({ signing, version, payload: payload(`v${version}`), key });
    return { id, envelope, response: await fetch(`${RELAY}/v1/shares/${id}`, json({ ...envelope, ...overrides })) };
  };
  return { kv, fetch, signing, key, upload };
}

test("the root says what it is", async () => {
  const response = await relayFetch(new FakeKV())(`${RELAY}/`);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /OpenArch share relay/);
});

test("a share is created, read and updated", async () => {
  const { kv, fetch, upload } = await setup();
  const first = await upload(1);
  assert.equal(first.response.status, 200);
  assert.deepEqual(await first.response.json(), { version: 1 });
  assert.equal(kv.ttls.get(`share:${first.id}`), 400 * 24 * 60 * 60);

  let response = await fetch(`${RELAY}/v1/shares/${first.id}`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("ETag"), '"1"');
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), "*");
  assert.deepEqual(await response.json(), first.envelope);

  const second = await upload(2);
  assert.equal(second.response.status, 200);
  response = await fetch(`${RELAY}/v1/shares/${first.id}`);
  assert.equal((await response.json()).version, 2);
});

test("only the known fields are kept", async () => {
  const { fetch, upload } = await setup();
  const { id } = await upload(1, { note: "x" });
  const stored = await (await fetch(`${RELAY}/v1/shares/${id}`)).json();
  assert.deepEqual(Object.keys(stored).sort(), ["blob", "pk", "sig", "v", "version"]);
});

test("the version has to go up", async () => {
  const { upload } = await setup();
  assert.equal((await upload(2)).response.status, 200);
  assert.equal((await upload(2)).response.status, 409);
  assert.equal((await upload(1)).response.status, 409);
  assert.equal((await upload(3)).response.status, 200);
});

test("a changed blob or a forged signature is refused", async () => {
  const { upload } = await setup();
  const { envelope } = await upload(1);
  const tampered = envelope.blob.slice(0, -2) + (envelope.blob.endsWith("AA") ? "AB" : "AA");
  assert.equal((await upload(2, { blob: tampered })).response.status, 403);
  assert.equal((await upload(2, { sig: b64uEncode(new Uint8Array(64)) })).response.status, 403);
});

test("an envelope cannot be put under another key's ID", async () => {
  const { fetch, upload } = await setup();
  const other = await generateSigningKey();
  const { id: otherID } = await makeEnvelope({ signing: other, version: 1, payload: payload("x"), key: generateContentKey() });
  const { envelope } = await upload(1);
  const response = await fetch(`${RELAY}/v1/shares/${otherID}`, json({ ...envelope, version: 2 }));
  assert.equal(response.status, 403);
});

test("malformed requests are refused", async () => {
  const { fetch, upload, signing } = await setup();
  const { id, envelope } = await upload(1);
  const put = (body) => fetch(`${RELAY}/v1/shares/${id}`, { method: "PUT", body });
  assert.equal((await put("not json")).status, 400);
  assert.equal((await put("[1]")).status, 400);
  assert.equal((await put(JSON.stringify({ ...envelope, v: 2 }))).status, 400);
  assert.equal((await put(JSON.stringify({ ...envelope, version: 0 }))).status, 400);
  assert.equal((await put(JSON.stringify({ ...envelope, version: 1.5 }))).status, 400);
  assert.equal((await put(JSON.stringify({ ...envelope, version: 2 ** 53 }))).status, 400);
  assert.equal((await put(JSON.stringify({ ...envelope, pk: envelope.pk.slice(1) }))).status, 400);
  assert.equal((await put(JSON.stringify({ ...envelope, sig: "AAAA" }))).status, 400);
  assert.equal((await fetch(`${RELAY}/v1/shares/short`)).status, 400);
  assert.equal((await fetch(`${RELAY}/v1/shares/${id}/x`)).status, 404);
  assert.equal((await fetch(`${RELAY}/v1/shares/${id}`, { method: "POST" })).status, 405);
  assert.ok(signing);
});

test("bodies over 256 KiB are refused, declared or not", async () => {
  const { fetch, upload } = await setup();
  const { id, envelope } = await upload(1);
  const big = JSON.stringify({ ...envelope, version: 2, blob: "A".repeat(256 * 1024) });
  let response = await fetch(`${RELAY}/v1/shares/${id}`, { method: "PUT", body: big });
  assert.equal(response.status, 413);

  // A stream without Content-Length.
  const bytes = new TextEncoder().encode(big);
  const stream = new ReadableStream({
    start(controller) {
      for (let i = 0; i < bytes.length; i += 16384) controller.enqueue(bytes.subarray(i, i + 16384));
      controller.close();
    },
  });
  response = await fetch(`${RELAY}/v1/shares/${id}`, { method: "PUT", body: stream, duplex: "half" });
  assert.equal(response.status, 413);

  // A declared size over the limit is refused before the body is read.
  const declared = new Request(`${RELAY}/v1/shares/${id}`, { method: "PUT", body: "{}", headers: { "Content-Length": "300000" } });
  if (declared.headers.get("Content-Length") === "300000") {
    response = await fetch(declared.url, { method: "PUT", body: "{}", headers: { "Content-Length": "300000" } });
    assert.equal(response.status, 413);
  }
});

test("ending a share leaves a marker that old uploads cannot get past", async () => {
  const { fetch, signing, upload } = await setup();
  const old = await upload(1);
  await upload(2);

  const unsigned = await fetch(`${RELAY}/v1/shares/${old.id}`, { method: "DELETE", body: JSON.stringify({ version: 3, sig: b64uEncode(new Uint8Array(64)) }) });
  assert.equal(unsigned.status, 403);
  const stale = await makeDeletion({ signing, version: 2 });
  assert.equal((await fetch(`${RELAY}/v1/shares/${old.id}`, { method: "DELETE", body: JSON.stringify(stale.body) })).status, 409);

  const deletion = await makeDeletion({ signing, version: 3 });
  let response = await fetch(`${RELAY}/v1/shares/${deletion.id}`, { method: "DELETE", body: JSON.stringify(deletion.body) });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { version: 3 });

  assert.equal((await fetch(`${RELAY}/v1/shares/${old.id}`)).status, 410);
  // The old signed upload, replayed, and even a newer one.
  assert.equal((await fetch(`${RELAY}/v1/shares/${old.id}`, json(old.envelope))).status, 410);
  assert.equal((await upload(9)).response.status, 410);
  response = await fetch(`${RELAY}/v1/shares/${old.id}`, { method: "DELETE", body: JSON.stringify((await makeDeletion({ signing, version: 4 })).body) });
  assert.equal(response.status, 410);
});

test("ending an unknown share is 404", async () => {
  const { fetch, signing } = await setup();
  const deletion = await makeDeletion({ signing, version: 1 });
  const response = await fetch(`${RELAY}/v1/shares/${deletion.id}`, { method: "DELETE", body: JSON.stringify(deletion.body) });
  assert.equal(response.status, 404);
  assert.equal((await fetch(`${RELAY}/v1/shares/${deletion.id}`)).status, 404);
});

test("If-None-Match with the current version is 304", async () => {
  const { fetch, upload } = await setup();
  const { id } = await upload(1);
  await upload(2);
  const get = (tag) => fetch(`${RELAY}/v1/shares/${id}`, { headers: { "If-None-Match": tag } });
  let response = await get('"2"');
  assert.equal(response.status, 304);
  assert.equal(response.headers.get("ETag"), '"2"');
  assert.equal(await response.text(), "");
  assert.equal((await get('W/"2"')).status, 304);
  assert.equal((await get('"1", "2"')).status, 304);
  assert.equal((await get('"1"')).status, 200);
});

test("CORS preflight is answered for GET, PUT and DELETE", async () => {
  const response = await relayFetch(new FakeKV())(`${RELAY}/v1/shares/AAAAAAAAAAAAAAAAAAAAAA`, {
    method: "OPTIONS",
    headers: { Origin: "https://openarch.app", "Access-Control-Request-Method": "PUT", "Access-Control-Request-Headers": "content-type" },
  });
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), "*");
  for (const method of ["GET", "PUT", "DELETE"]) {
    assert.match(response.headers.get("Access-Control-Allow-Methods"), new RegExp(method));
  }
  assert.match(response.headers.get("Access-Control-Allow-Headers"), /Content-Type/);
  assert.match(response.headers.get("Access-Control-Allow-Headers"), /If-None-Match/);
  assert.equal(response.headers.get("Access-Control-Allow-Credentials"), null);
});
