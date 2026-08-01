import test from "node:test";
import assert from "node:assert/strict";

globalThis.localStorage = { getItem: () => null, removeItem: () => {} };
const { shouldReloadPairingLink } = await import("../../Sources/PatchworkWeb/Site/js/relay.js");

test("a new QR fragment reloads an existing Safari pairing tab", () => {
  assert.equal(shouldReloadPairingLink("/pair/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "#ticket=new&host=key"), true);
  assert.equal(shouldReloadPairingLink("/pair/too-short", "#ticket=new&host=key"), false);
  assert.equal(shouldReloadPairingLink("/pair/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ""), false);
  assert.equal(shouldReloadPairingLink("/", "#ticket=new&host=key"), false);
});
