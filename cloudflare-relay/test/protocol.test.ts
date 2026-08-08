import assert from "node:assert/strict";
import test from "node:test";

import {
  decodeBase64,
  encodeBase64,
  parseHostFrame,
  proxyHeaders,
  route,
} from "../src/protocol.js";

test("routes one opaque installation without exposing an origin", () => {
  const id = "0123456789abcdef0123456789abcdef";
  assert.deepEqual(route(`/connect/${id}`), { role: "host", relayId: id });
  assert.deepEqual(route(`/r/${id}/w/one/api/bootstrap`), {
    role: "client",
    relayId: id,
    localPath: "/w/one/api/bootstrap",
  });
  assert.equal(route("/r/not-an-id/api/health"), null);
  assert.equal(route(`/other/${id}`), null);
});

test("proxy headers keep auth and content type but drop transport metadata", () => {
  const headers = new Headers({
    authorization: "Bearer device",
    "content-type": "application/json",
    connection: "keep-alive",
    host: "relay.patchwork.sh",
    "cf-ray": "private-edge-metadata",
  });
  assert.deepEqual(proxyHeaders(headers), [
    ["authorization", "Bearer device"],
    ["content-type", "application/json"],
  ]);
});

test("host frames and binary bodies fail closed", () => {
  const body = new Uint8Array([0, 1, 2, 253, 254, 255]);
  assert.deepEqual(decodeBase64(encodeBase64(body)), body);
  assert.ok(parseHostFrame({
    type: "response",
    id: "0123456789abcdefghij-_",
    status: 200,
    headers: [["content-type", "application/json"]],
    body: "e30=",
  }));
  assert.equal(parseHostFrame({ type: "response", id: "bad", status: 200, headers: [], body: "" }), null);
  assert.equal(parseHostFrame({ type: "socket_data", id: "0123456789abcdefghij-_", data: 4 }), null);
});
