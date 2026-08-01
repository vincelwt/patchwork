// Node-only checks for the pure time helpers (Sources/PatchworkWeb/Site/js/time.mjs).
import test from "node:test";
import assert from "node:assert/strict";
import { relativeTime, clockTime } from "../../Sources/PatchworkWeb/Site/js/time.mjs";

const NOW = new Date("2026-06-15T12:00:00Z");

test("relativeTime: compact units for the recent past", () => {
  assert.equal(relativeTime(new Date(NOW - 2000), NOW), "now");
  assert.equal(relativeTime(new Date(NOW - 30000), NOW), "30s");
  assert.equal(relativeTime(new Date(NOW - 5 * 60000), NOW), "5m");
  assert.equal(relativeTime(new Date(NOW - 3 * 3600000), NOW), "3h");
  assert.equal(relativeTime(new Date(NOW - 2 * 86400000), NOW), "2d");
});

test("relativeTime: future timestamps read as 'in Xy'", () => {
  assert.equal(relativeTime(new Date(NOW.getTime() + 5 * 60000), NOW), "in 5m");
  assert.equal(relativeTime(new Date(NOW.getTime() + 3600000), NOW), "in 1h");
});

test("relativeTime: falls back to an absolute date past a week", () => {
  const out = relativeTime(new Date(NOW - 30 * 86400000), NOW);
  assert.ok(!/^\d+[smhd]$/.test(out), `expected an absolute date, got "${out}"`);
  assert.ok(out.length > 0);
});

test("relativeTime: unparsable input returns an empty string, never throws", () => {
  assert.equal(relativeTime("not a date", NOW), "");
  assert.equal(relativeTime(undefined, NOW), "");
});

test("clockTime: valid ISO input produces a non-empty label; invalid input is empty", () => {
  assert.ok(clockTime("2026-06-15T12:00:00Z").length > 0);
  assert.equal(clockTime("nope"), "");
});
