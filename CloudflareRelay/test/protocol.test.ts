import assert from "node:assert/strict";
import test from "node:test";
import { freshMutableAsset } from "../src/assets.js";
import {
  broadcastHostPresence,
  challengeData,
  cipherPayload,
  decodeBase64url,
  encodeBase64url,
  equalFixed,
  frameByteLength,
  hostPresenceMessage,
  isConnectionID,
  isInstallationID,
  isName,
  isToken,
  p256PublicKey,
  publicJwk,
  relayRoute,
  sha256Base64url,
} from "../src/protocol.js";

const bytes = (length: number) => Uint8Array.from({ length }, (_, index) => index);
const coordinate = encodeBase64url(bytes(32));

test("base64url utilities are canonical and length-aware", () => {
  const encoded = encodeBase64url(bytes(32));
  assert.deepEqual(decodeBase64url(encoded, 32), bytes(32));
  assert.equal(decodeBase64url(`${encoded}=`, 32), null);
  assert.equal(decodeBase64url("A", 1), null);
  assert.equal(isToken(encoded), true);
  assert.equal(isToken(encodeBase64url(bytes(31))), false);
  assert.equal(equalFixed(encoded, encoded), true);
  assert.equal(equalFixed(encoded, `${encoded.slice(0, -1)}A`), false);
});

test("SHA-256 hashes UTF-8 token text to base64url", async () => {
  assert.equal(await sha256Base64url("abc"), "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0");
});

test("challenge and host-presence messages match the protocol", () => {
  const installationID = "i".repeat(32);
  const deviceID = "d".repeat(32);
  const nonce = encodeBase64url(bytes(32));
  assert.equal(new TextDecoder().decode(challengeData(installationID, deviceID, nonce)), `pi-remote-v1:${installationID}:${deviceID}:${nonce}`);
  assert.deepEqual(hostPresenceMessage(true), { type: "hostOnline" });
  assert.deepEqual(hostPresenceMessage(false), { type: "hostOffline" });
  const delivered: Array<[number, { type: "hostOnline" | "hostOffline" }]> = [];
  broadcastHostPresence([1, 2, 3], true, (socket, message) => delivered.push([socket, message]));
  assert.deepEqual(delivered, [[1, { type: "hostOnline" }], [2, { type: "hostOnline" }], [3, { type: "hostOnline" }]]);
  assert.equal(frameByteLength({ type: "hostOnline" }), 21);
});

test("route, identifiers, and names are strictly bounded", () => {
  const installationID = "A_-b".repeat(8);
  assert.equal(isInstallationID(installationID), true);
  assert.deepEqual(relayRoute(`/relay/device/${installationID}`), { role: "device", installationID });
  assert.equal(relayRoute(`/relay/device/${installationID}/`), null);
  assert.equal(isInstallationID("A".repeat(31)), false);
  assert.equal(isConnectionID(encodeBase64url(bytes(16))), true);
  assert.equal(isConnectionID(encodeBase64url(bytes(15))), false);
  const p256 = encodeBase64url(Uint8Array.from([4, ...bytes(64)]));
  assert.equal(p256PublicKey(p256), p256);
  assert.equal(p256PublicKey(encodeBase64url(bytes(65))), null);
  assert.equal(isName("Laptop"), true);
  assert.equal(isName(" Laptop"), false);
  assert.equal(isName("x".repeat(65)), false);
});

test("public JWK and cipher payload helpers reject extra or malformed data", () => {
  const jwk = { kty: "EC", crv: "P-256", x: coordinate, y: coordinate, ext: true, key_ops: ["verify"] };
  assert.deepEqual(publicJwk(jwk), { kty: "EC", crv: "P-256", x: coordinate, y: coordinate, ext: true });
  assert.equal(publicJwk({ ...jwk, d: coordinate }), null);
  assert.equal(publicJwk({ ...jwk, key_ops: ["sign"] }), null);
  assert.equal(publicJwk({ ...jwk, x: encodeBase64url(bytes(31)) }), null);

  const payload = { nonce: encodeBase64url(bytes(12)), data: encodeBase64url(Uint8Array.of(1, 2, 3)) };
  assert.deepEqual(cipherPayload(payload), payload);
  assert.equal(cipherPayload({ ...payload, extra: true }), null);
  assert.equal(cipherPayload({ ...payload, nonce: encodeBase64url(bytes(11)) }), null);
});

test("mutable assets bypass bodyless Safari 304 responses", async () => {
  let forwarded: Request | undefined;
  const assets = {
    async fetch(request: Request) {
      forwarded = request;
      return new Response("asset body", { headers: { etag: '"current"' } });
    },
  };
  const stale = new Request("https://remote.ai.gloom.sh/js/app.js", {
    headers: { "if-none-match": '"current"', "if-modified-since": "yesterday" },
  });

  const response = await freshMutableAsset(stale, assets);

  assert.equal(forwarded?.headers.has("if-none-match"), false);
  assert.equal(forwarded?.headers.has("if-modified-since"), false);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("etag"), '"current"');
  assert.equal(await response.text(), "asset body");

  const icon = new Request("https://remote.ai.gloom.sh/favicon.svg", { headers: { "if-none-match": '"icon"' } });
  await freshMutableAsset(icon, assets);
  assert.equal(forwarded, icon);
});
