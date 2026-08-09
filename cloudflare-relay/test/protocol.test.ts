import assert from "node:assert/strict";
import test from "node:test";

import {
  clientToken,
  compactId,
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

  const preview = "019fe30c-fe6f-7ff0-8829-931a29a63576";
  assert.equal(compactId(id), "2fapl4n1azs5kkwzrxa98bn3");
  assert.deepEqual(
    route("/checkout", `p-${compactId(id)}-${compactId(preview)}.patchwork.sh`),
    {
      role: "client",
      relayId: id,
      localPath: `/preview/${preview}/checkout`,
      preview: true,
    },
  );
  assert.equal(route("/", `p-${"z".repeat(25)}-1.patchwork.sh`), null);
});

test("only app sockets expose a device token for reconnection", () => {
  const path = "/w/one/ws?token=device-token&since=4";
  assert.equal(clientToken(path), "device-token");
  assert.equal(clientToken(path, true), null);
  assert.equal(clientToken("/w/one/api/bootstrap?token=device-token"), null);
});

test("proxy headers keep auth and content type but drop transport metadata", () => {
  const headers = new Headers({
    authorization: "Bearer device",
    "content-type": "application/json",
    connection: "keep-alive",
    host: "relay.patchwork.sh",
    "cf-ray": "private-edge-metadata",
    "sec-websocket-key": "private",
    "sec-websocket-protocol": "vite-hmr",
  });
  assert.deepEqual(proxyHeaders(headers), [
    ["authorization", "Bearer device"],
    ["content-type", "application/json"],
    ["sec-websocket-protocol", "vite-hmr"],
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
