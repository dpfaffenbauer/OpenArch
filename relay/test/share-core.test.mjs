import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_RELAY, ShareError, SNAPSHOT_AAD, aesSeal, b64uDecode, b64uEncode, buildFragment, decodePayload,
  encodePayload, fetchLive, generateContentKey, generateSigningKey, liveAAD, makeEnvelope, openEnvelope,
  openLink, parseFragment, putMessage, sanitize, sealPayload, sign, wrapPassword,
} from "../../website/s/share-core.js";
import { FakeKV, RELAY, json, relayFetch } from "./helpers.mjs";

const TAB = "6F1C2F8E-1D2B-4C1E-9A55-0B1C2D3E4F50";
const FOLDER = "A0B21C3D-4E5F-4061-8273-94A5B6C7D8E9";
const INNER = "C3D4E5F6-0718-4293-A4B5-C6D7E8F90A1B";
const payload = {
  v: 1, kind: "folder", name: "Geteilt ✓", updated: "2026-10-30T10:00:00Z",
  items: [
    { id: TAB, title: "Example", url: "https://example.com/" },
    { id: FOLDER, title: "Docs", icon: "book.fill", children: [
      { id: INNER, title: "Apple", url: "https://developer.apple.com/" },
    ] },
  ],
};

async function rejects(promise, code) {
  await assert.rejects(promise, (error) => error instanceof ShareError && error.code === code);
}

test("base64url is strict", () => {
  const bytes = new Uint8Array([0xfb, 0xff, 0xbf, 0, 1]);
  assert.equal(b64uEncode(bytes), "-_-_AAE");
  assert.deepEqual(b64uDecode("-_-_AAE"), bytes);
  for (const bad of ["+/+/", "AAE=", "A", "AB C", "AAF"]) {
    assert.throws(() => b64uDecode(bad), (error) => error.code === "invalid-link", bad);
  }
});

test("a snapshot opens with the key in the link", async () => {
  const key = generateContentKey();
  const blob = await sealPayload(payload, key, SNAPSHOT_AAD);
  const fragment = buildFragment({ mode: "snapshot", blob, keySlot: { type: "key", bytes: key } });
  assert.match(fragment, /^1\.s\.[A-Za-z0-9_-]+\.k[A-Za-z0-9_-]{43}$/);
  const result = await openLink("#" + fragment);
  assert.equal(result.link.mode, "snapshot");
  assert.deepEqual(result.payload, payload);
});

test("a snapshot with a password opens with the password only", async () => {
  const key = generateContentKey();
  const blob = await sealPayload(payload, key, SNAPSHOT_AAD);
  const slot = await wrapPassword(key, "correct horse");
  assert.equal(slot.length, 76);
  const fragment = buildFragment({ mode: "snapshot", blob, keySlot: { type: "password", bytes: slot } });
  assert.match(fragment, /\.p[A-Za-z0-9_-]{102}$/);
  assert.deepEqual((await openLink(fragment, { password: "correct horse" })).payload, payload);
  // NFC: the same password typed with a combining character.
  const nfc = await wrapPassword(key, "Grüße");
  const link = buildFragment({ mode: "snapshot", blob, keySlot: { type: "password", bytes: nfc } });
  assert.deepEqual((await openLink(link, { password: "Grüße" })).payload, payload);
  await rejects(openLink(fragment, { password: "wrong horse" }), "wrong-password");
  await rejects(openLink(fragment), "wrong-password");
});

test("a live share goes through the relay, updates and stays verified", async () => {
  const kv = new FakeKV();
  const fetch = relayFetch(kv);
  const signing = await generateSigningKey();
  const key = generateContentKey();
  const put = async (version, content) => {
    const { id, envelope } = await makeEnvelope({ signing, version, payload: content, key });
    const response = await fetch(`${RELAY}/v1/shares/${id}`, json(envelope));
    assert.equal(response.status, 200);
    return id;
  };
  const id = await put(1, payload);
  const fragment = buildFragment({ mode: "live", id, keySlot: { type: "key", bytes: key }, relay: RELAY });
  assert.match(fragment, /^1\.l\.[A-Za-z0-9_-]{22}\.k[A-Za-z0-9_-]{43}\.r[A-Za-z0-9_-]+$/);
  const link = parseFragment(fragment);
  assert.equal(link.relay, RELAY);

  let result = await openLink(fragment, { fetch });
  assert.equal(result.version, 1);
  assert.deepEqual(result.payload, payload);

  await put(2, { ...payload, name: "Neu" });
  result = await fetchLive(id, key, RELAY, { fetch, lastVersion: 1 });
  assert.equal(result.version, 2);
  assert.equal(result.payload.name, "Neu");
  result = await fetchLive(id, key, RELAY, { fetch, lastVersion: 2 });
  assert.deepEqual(result, { notModified: true, version: 2 });

  // Wrong key: AES-GCM fails.
  await rejects(fetchLive(id, generateContentKey(), RELAY, { fetch }), "damaged");
  // Unknown and unreachable.
  await rejects(fetchLive("A".repeat(22), key, RELAY, { fetch }), "not-found");
  await rejects(fetchLive(id, key, RELAY, { fetch: async () => { throw new TypeError("offline"); } }), "unreachable");
});

test("the default relay is left out of links", () => {
  const keySlot = { type: "key", bytes: new Uint8Array(32) };
  const id = "A".repeat(22);
  assert.equal(buildFragment({ mode: "live", id, keySlot, relay: DEFAULT_RELAY }).split(".").length, 4);
  assert.equal(buildFragment({ mode: "live", id, keySlot, relay: DEFAULT_RELAY + "/" }).split(".").length, 4);
  assert.equal(buildFragment({ mode: "live", id, keySlot }).split(".").length, 4);
  assert.equal(parseFragment(buildFragment({ mode: "live", id, keySlot })).relay, null);
});

test("tampering, a wrong version and someone else's key are caught", async () => {
  const signing = await generateSigningKey();
  const key = generateContentKey();
  const { id, envelope } = await makeEnvelope({ signing, version: 1, payload, key });
  assert.deepEqual((await openEnvelope(envelope, id, key)).payload, payload);

  // One byte of the ciphertext changed, re-signed by the owner: AES-GCM fails.
  const blob = b64uDecode(envelope.blob);
  blob[20] ^= 1;
  const tampered = b64uEncode(blob);
  const resigned = { ...envelope, blob: tampered, sig: b64uEncode(await sign(signing.privateKey, putMessage(id, 1, tampered))) };
  await rejects(openEnvelope(resigned, id, key), "damaged");

  // Changed without the owner's key: the signature fails.
  await rejects(openEnvelope({ ...envelope, blob: tampered }, id, key), "damaged");

  // The blob of version 1 presented as version 2 (signed): the AAD differs.
  const relabelled = { ...envelope, version: 2, sig: b64uEncode(await sign(signing.privateKey, putMessage(id, 2, envelope.blob))) };
  await rejects(openEnvelope(relabelled, id, key), "damaged");

  // Another key's envelope under this ID.
  const other = await makeEnvelope({ signing: await generateSigningKey(), version: 1, payload, key });
  await rejects(openEnvelope(other.envelope, id, key), "damaged");

  // Malformed envelopes.
  await rejects(openEnvelope({ ...envelope, v: 2 }, id, key), "damaged");
  await rejects(openEnvelope({ ...envelope, version: 0 }, id, key), "damaged");
  await rejects(openEnvelope(null, id, key), "damaged");
});

test("an older version than the one seen is refused", async () => {
  const signing = await generateSigningKey();
  const key = generateContentKey();
  const { id, envelope } = await makeEnvelope({ signing, version: 3, payload, key });
  assert.equal((await openEnvelope(envelope, id, key, { lastVersion: 3 })).version, 3);
  await rejects(openEnvelope(envelope, id, key, { lastVersion: 4 }), "rollback");
  // A relay that hands out an old envelope.
  const fetch = async () => new Response(JSON.stringify(envelope), { status: 200 });
  await rejects(fetchLive(id, key, RELAY, { fetch, lastVersion: 5 }), "rollback");
});

test("relay answers become errors", async () => {
  const key = generateContentKey();
  const id = "A".repeat(22);
  const answer = (status) => async () => new Response(status === 200 ? "not json" : null, { status });
  await rejects(fetchLive(id, key, RELAY, { fetch: answer(410) }), "ended");
  await rejects(fetchLive(id, key, RELAY, { fetch: answer(404) }), "not-found");
  await rejects(fetchLive(id, key, RELAY, { fetch: answer(500) }), "server");
  await rejects(fetchLive(id, key, RELAY, { fetch: answer(200) }), "damaged");
});

test("sanitize keeps web links and drops the rest", () => {
  const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const clean = sanitize({
    v: 1, kind: "space", name: "  Space  ", color: "#12ab9F", icon: "🎨", extra: true,
    items: [
      { id: id(1), title: "ok", url: "https://example.com/a" },
      { id: id(2), title: "http", url: "http://example.com/" },
      { id: id(3), title: "js", url: "javascript:alert(1)" },
      { id: id(4), title: "js", url: " JavaScript:alert(1)" },
      { id: id(5), title: "file", url: "file:///etc/passwd" },
      { id: id(6), title: "data", url: "data:text/html,<script>alert(1)</script>" },
      { id: id(7), title: "no url" },
      { id: "not-a-uuid", title: "bad id", url: "https://example.com/" },
      { id: id(8), title: "x".repeat(400), url: "https://example.com/long", icon: "ignored" },
      { id: id(9), title: 5, url: "https://example.com/number" },
      { id: id(10), title: "folder", url: "https://ignored.example/", children: [
        { id: id(11), url: "vbscript:x" },
      ] },
    ],
  });
  assert.equal(clean.name, "Space");
  assert.equal(clean.color, "#12ab9F");
  assert.equal(clean.icon, "🎨");
  assert.equal(clean.extra, undefined);
  assert.deepEqual(clean.items.map((node) => node.id), [id(1), id(2), id(8), id(9), id(10)]);
  assert.equal(clean.items[2].title.length, 300);
  assert.equal(clean.items[2].icon, undefined);
  assert.equal(clean.items[3].title, "");
  assert.deepEqual(clean.items[4], { id: id(10), title: "folder", children: [] });
  assert.equal(sanitize({ v: 1, kind: "space", name: "x", color: "red", items: [] }).color, undefined);
  assert.equal(sanitize({ v: 1, kind: "other", name: "x", items: [] }).kind, "folder");
});

test("sanitize stops at 16 levels and 5000 entries", () => {
  let counter = 0;
  const id = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;
  let deep = [{ id: id(), title: "leaf", url: "https://example.com/" }];
  for (let level = 0; level < 20; level++) deep = [{ id: id(), title: `level ${level}`, children: deep }];
  let depth = 0;
  for (let nodes = sanitize({ v: 1, kind: "folder", name: "d", items: deep }).items; nodes?.length; nodes = nodes[0].children) depth++;
  assert.equal(depth, 16);

  const many = Array.from({ length: 6000 }, () => ({ id: id(), title: "t", url: "https://example.com/" }));
  assert.equal(sanitize({ v: 1, kind: "folder", name: "m", items: many }).items.length, 5000);
});

test("payloads: both formats, newer versions and bombs", async () => {
  assert.deepEqual(await decodePayload(await encodePayload(payload, { compress: false })), payload);
  assert.deepEqual(await decodePayload(await encodePayload(payload)), payload);
  await rejects(decodePayload(await encodePayload({ ...payload, v: 2 })), "unsupported");
  await rejects(decodePayload(new Uint8Array([2, 0x7b, 0x7d])), "unsupported");
  await rejects(decodePayload(new Uint8Array([0, 0x7b])), "damaged");
  await rejects(decodePayload(new Uint8Array([1, 0xff, 0xff, 0xff])), "damaged");
  await rejects(decodePayload(new Uint8Array([])), "damaged");
  await rejects(decodePayload(await encodePayload({ v: 1, kind: "folder", name: "x" })), "damaged");

  // 5 MiB of spaces packed into a few KiB: refused while inflating.
  const stream = new Blob([new Uint8Array(5 * 1024 * 1024).fill(0x20)]).stream().pipeThrough(new CompressionStream("deflate-raw"));
  const bomb = new Uint8Array(await new Response(stream).arrayBuffer());
  assert.ok(bomb.length < 32 * 1024);
  await rejects(decodePayload(new Uint8Array([1, ...bomb])), "damaged");
});

test("a snapshot sealed with the live AAD does not open as a snapshot", async () => {
  const key = generateContentKey();
  const blob = await aesSeal(key, await encodePayload(payload), liveAAD("A".repeat(22), 1));
  const fragment = buildFragment({ mode: "snapshot", blob, keySlot: { type: "key", bytes: key } });
  await rejects(openLink(fragment), "damaged");
});

test("malformed links are refused", () => {
  const key = "k" + b64uEncode(new Uint8Array(32));
  const id = "A".repeat(22);
  const blob = b64uEncode(new Uint8Array(40));
  const relay = (url) => "r" + b64uEncode(new TextEncoder().encode(url));
  const bad = [
    "", "#", "1", `1.l.${id}`, `1.x.${id}.${key}`, `1.l.${id}.${key}.${relay(RELAY)}.x`,
    `1.l.${id.slice(1)}.${key}`, `1.l.${id}A.${key}`, `1.l.${id}.k${b64uEncode(new Uint8Array(31))}`,
    `1.l.${id}.p${b64uEncode(new Uint8Array(32))}`, `1.l.${id}.x${b64uEncode(new Uint8Array(32))}`,
    `1.s.${b64uEncode(new Uint8Array(20))}.${key}`, `1.s.${blob}.${key}.${relay(RELAY)}`,
    `1.l.${id}.${key}.${relay("http://evil.example")}`, `1.l.${id}.${key}.${relay("javascript:alert(1)")}`,
    `1.l.${id}.${key}.${relay("https://user:pw@relay.example")}`, `1.l.${id}.${key}.x${b64uEncode(new Uint8Array(3))}`,
    `x.l.${id}.${key}`, `1.l.${id}.${key.slice(0, -1)}+`,
  ];
  for (const fragment of bad) {
    assert.throws(() => parseFragment(fragment), (error) => error instanceof ShareError && error.code === "invalid-link", fragment);
  }
  assert.throws(() => parseFragment(`2.l.${id}.${key}`), (error) => error.code === "unsupported");
  assert.equal(parseFragment(`1.l.${id}.${key}.${relay("http://localhost:8787")}`).relay, "http://localhost:8787");
  assert.equal(parseFragment(`1.l.${id}.${key}.${relay("https://relay.example/base/")}`).relay, "https://relay.example/base");
});
