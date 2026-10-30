// The vectors in Shared/Tests/OpenArchSharedTests/Vectors.swift open here,
// and their keys are the ones make-vectors.mjs says they are. (The bytes
// themselves are not compared: another zlib may compress differently.)
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  b64uDecode, b64uEncode, deleteMessage, derivePasswordKey, importSigningSeed, openEnvelope, openLink, sanitize,
  shareIdFor,
} from "../../website/s/share-core.js";
import { DELETE_VERSION, LIVE_RELAY, LIVE_VERSION, PASSWORD, SWIFT_FILE, bytes, payload } from "./make-vectors.mjs";

function readSwift() {
  const source = readFileSync(SWIFT_FILE, "utf8");
  const vectors = {};
  for (const match of source.matchAll(/static let (\w+) = (?:#"(.*)"#|(\d+))$/gm)) {
    vectors[match[1]] = match[2] ?? Number(match[3]);
  }
  return vectors;
}

test("the Swift vectors are complete and open in JavaScript", async () => {
  const v = readSwift();
  assert.equal(Object.keys(v).length, 19);
  assert.deepEqual(JSON.parse(v.payloadJSON), payload);
  const kept = sanitize(payload);
  assert.deepEqual(JSON.parse(v.sanitizedPayloadJSON), kept);
  assert.equal(kept.items.length, 2);

  assert.deepEqual(b64uDecode(v.contentKey), bytes(0, 32));
  assert.deepEqual(b64uDecode(v.signingSeed), bytes(32, 32));
  const signing = await importSigningSeed(bytes(32, 32));
  assert.equal(v.publicKey, b64uEncode(signing.publicKey));
  assert.equal(v.shareID, await shareIdFor(signing.publicKey));
  assert.equal(v.password, PASSWORD);
  assert.equal(v.passwordWrapKey, b64uEncode(await derivePasswordKey(PASSWORD, b64uDecode(v.passwordSalt))));

  assert.deepEqual((await openLink(v.snapshotFragment)).payload, kept);
  assert.deepEqual((await openLink(v.snapshotPasswordFragment, { password: PASSWORD })).payload, kept);
  assert.ok(v.snapshotPasswordFragment.endsWith("p" + v.passwordSlot));

  assert.equal(v.liveVersion, LIVE_VERSION);
  const opened = await openEnvelope(JSON.parse(v.liveEnvelopeJSON), v.shareID, bytes(0, 32));
  assert.equal(opened.version, LIVE_VERSION);
  assert.deepEqual(opened.payload, kept);
  assert.equal(v.liveFragment, `1.l.${v.shareID}.k${v.contentKey}`);
  assert.equal(v.liveRelay, LIVE_RELAY);
  assert.equal((await import("../../website/s/share-core.js")).parseFragment(v.liveFragmentWithRelay).relay, LIVE_RELAY);

  assert.equal(v.deleteVersion, DELETE_VERSION);
  const key = await crypto.subtle.importKey("raw", signing.publicKey, { name: "Ed25519" }, false, ["verify"]);
  assert.ok(await crypto.subtle.verify({ name: "Ed25519" }, key, b64uDecode(v.deleteSignature),
    new TextEncoder().encode(deleteMessage(v.shareID, DELETE_VERSION))));
});
