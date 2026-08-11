import assert from "node:assert/strict";
import test from "node:test";

import {
  activate,
  decodePaired,
  encodePaired,
  withName,
  withSession,
  withoutSession,
  workspaceInitials,
  workspaceSymbol,
  type PairedSession,
} from "./paired.ts";

const acme: PairedSession = { baseUrl: "https://relay.example/w/acme", token: "one", name: "Acme" };
const nightshade: PairedSession = { baseUrl: "https://relay.example/w/night", token: "two" };

test("a device paired before multi-workspace support keeps its workspace", () => {
  const paired = decodePaired(JSON.stringify({ baseUrl: acme.baseUrl, token: acme.token }));
  assert.equal(paired.all.length, 1);
  assert.equal(paired.active?.baseUrl, acme.baseUrl);
});

test("workspaces survive a round trip and remember which one was active", () => {
  const paired = activate(withSession(withSession(decodePaired(null), acme), nightshade), acme.baseUrl);
  const restored = decodePaired(encodePaired(paired));
  assert.deepEqual(restored.all.map((item) => item.baseUrl), [acme.baseUrl, nightshade.baseUrl]);
  assert.equal(restored.active?.baseUrl, acme.baseUrl);
});

test("pairing the same workspace again replaces its key instead of duplicating it", () => {
  const paired = withSession(withSession(decodePaired(null), acme), { ...acme, token: "rotated" });
  assert.equal(paired.all.length, 1);
  assert.equal(paired.active?.token, "rotated");
});

test("signing out of the active workspace falls back to another paired one", () => {
  const paired = withoutSession(withSession(withSession(decodePaired(null), acme), nightshade), nightshade);
  assert.equal(paired.all.length, 1);
  assert.equal(paired.active?.baseUrl, acme.baseUrl);
  assert.equal(withoutSession(paired, acme).active, null);
});

test("insecure relays are only accepted when development explicitly allows them", () => {
  const raw = JSON.stringify({ sessions: [{ baseUrl: "http://127.0.0.1:7799/w/dev", token: "t" }], active: "" });
  assert.equal(decodePaired(raw).all.length, 0);
  assert.equal(decodePaired(raw, true).all.length, 1);
});

test("names refresh from the workspace without disturbing the active choice", () => {
  const paired = activate(withSession(withSession(decodePaired(null), acme), nightshade), acme.baseUrl);
  const named = withName(paired, nightshade.baseUrl, "Nightshade Studio");
  assert.equal(named.all[1].name, "Nightshade Studio");
  assert.equal(named.active?.baseUrl, acme.baseUrl);
  assert.equal(withName(named, nightshade.baseUrl, "Nightshade Studio"), named);
});

test("a workspace without a name is labelled by its relay host", () => {
  assert.equal(workspaceInitials(acme), "A");
  assert.equal(workspaceInitials(nightshade), "RE");
});

test("the tab bar symbol is the workspace's own initial", () => {
  assert.deepEqual(workspaceSymbol(acme), { default: "a.square", selected: "a.square.fill" });
  // No letter symbol exists outside a-z0-9, and nothing is paired yet either.
  assert.deepEqual(workspaceSymbol({ ...acme, name: "\u5b57\u5178" }), {
    default: "square.grid.2x2",
    selected: "square.grid.2x2.fill",
  });
  assert.deepEqual(workspaceSymbol(null), { default: "square.grid.2x2", selected: "square.grid.2x2.fill" });
});
