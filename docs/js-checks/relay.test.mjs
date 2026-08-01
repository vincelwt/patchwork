import test from "node:test";
import assert from "node:assert/strict";
import {
  base64URL,
  challengeText,
  decryptJSON,
  deriveSessionKey,
  encryptJSON,
  fromBase64URL,
  pairingCredentials,
  pairingTranscript
} from "../../Sources/PatchworkWeb/Site/js/relayCrypto.mjs";

test("relay base64url and challenge wire format are stable", () => {
  const bytes = Uint8Array.from([0, 1, 2, 253, 254, 255]);
  assert.deepEqual(fromBase64URL(base64URL(bytes)), bytes);
  assert.equal(challengeText("install", "device", "nonce"), "pi-remote-v1:install:device:nonce");
  assert.equal(
    pairingTranscript("install", "device", "Phone", "ecdh", { x: "x", y: "y" }),
    "pi-remote-pair-v1\0install\0device\0Phone\0ecdh\0x\0y"
  );
});

test("pairing proof binds the ticket and both device keys", async () => {
  const ticket = base64URL(Uint8Array.from({ length: 32 }, (_, index) => index));
  const authPublicKey = { x: "x-coordinate", y: "y-coordinate" };
  const first = await pairingCredentials(ticket, "installation", "device", "Phone", "ecdh", authPublicKey);
  const same = await pairingCredentials(ticket, "installation", "device", "Phone", "ecdh", authPublicKey);
  const changed = await pairingCredentials(ticket, "installation", "other", "Phone", "ecdh", authPublicKey);
  assert.deepEqual(first, same);
  assert.notEqual(first.proof, changed.proof);
  assert.match(first.verificationCode, /^\d{6}$/);
  assert.equal(fromBase64URL(first.proof).length, 32);
  assert.equal(fromBase64URL(first.ticketHash).length, 32);
});

test("paired P-256 keys derive direction-bound AES-GCM keys", async () => {
  const host = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const device = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const hostPublic = base64URL(await crypto.subtle.exportKey("raw", host.publicKey));
  const devicePublic = base64URL(await crypto.subtle.exportKey("raw", device.publicKey));
  const browserKey = await deriveSessionKey(device.privateKey, hostPublic, "installation", "device");
  const daemonKey = await deriveSessionKey(host.privateKey, devicePublic, "installation", "device");
  const payload = await encryptJSON({ id: "request-1", text: "hello" }, browserKey, "device-to-host");
  assert.deepEqual(await decryptJSON(payload, daemonKey, "device-to-host"), { id: "request-1", text: "hello" });
  await assert.rejects(() => decryptJSON(payload, daemonKey, "host-to-device"));
});
