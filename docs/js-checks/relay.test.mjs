import test from "node:test";
import assert from "node:assert/strict";
import {
  base64URL,
  challengeText,
  decryptJSON,
  deriveSessionKey,
  encryptJSON,
  fromBase64URL
} from "../../Sources/PiDeskWeb/Site/js/relayCrypto.mjs";

test("relay base64url and challenge wire format are stable", () => {
  const bytes = Uint8Array.from([0, 1, 2, 253, 254, 255]);
  assert.deepEqual(fromBase64URL(base64URL(bytes)), bytes);
  assert.equal(challengeText("install", "device", "nonce"), "pi-remote-v1:install:device:nonce");
});

test("paired P-256 keys derive interoperable AES-GCM keys", async () => {
  const host = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const device = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const hostPublic = base64URL(await crypto.subtle.exportKey("raw", host.publicKey));
  const devicePublic = base64URL(await crypto.subtle.exportKey("raw", device.publicKey));
  const browserKey = await deriveSessionKey(device.privateKey, hostPublic, "installation", "device");
  const daemonKey = await deriveSessionKey(host.privateKey, devicePublic, "installation", "device");
  const payload = await encryptJSON({ id: "request-1", text: "hello" }, browserKey);
  assert.deepEqual(await decryptJSON(payload, daemonKey), { id: "request-1", text: "hello" });
});
