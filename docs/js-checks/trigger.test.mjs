// Node-only checks for the pure schedule-trigger helpers (Sources/PiDeskWeb/Site/js/trigger.mjs).
import test from "node:test";
import assert from "node:assert/strict";
import {
  parseDurationToSeconds,
  formatSecondsAsDuration,
  looksLikeCron,
  buildTrigger,
  triggerSummary
} from "../../Sources/PiDeskWeb/Site/js/trigger.mjs";

test("parseDurationToSeconds: units and bare numbers", () => {
  assert.equal(parseDurationToSeconds("15m"), 900);
  assert.equal(parseDurationToSeconds("2h"), 7200);
  assert.equal(parseDurationToSeconds("1d"), 86400);
  assert.equal(parseDurationToSeconds("90s"), 90);
  assert.equal(parseDurationToSeconds("45"), 45);
  assert.equal(parseDurationToSeconds(30), 30);
});

test("parseDurationToSeconds: rejects garbage and non-positive values", () => {
  assert.equal(parseDurationToSeconds("abc"), null);
  assert.equal(parseDurationToSeconds("0m"), null);
  assert.equal(parseDurationToSeconds("-5m"), null);
  assert.equal(parseDurationToSeconds(""), null);
  assert.equal(parseDurationToSeconds(undefined), null);
});

test("formatSecondsAsDuration is the inverse of parseDurationToSeconds for round units", () => {
  assert.equal(formatSecondsAsDuration(900), "15m");
  assert.equal(formatSecondsAsDuration(7200), "2h");
  assert.equal(formatSecondsAsDuration(86400), "1d");
  assert.equal(formatSecondsAsDuration(30), "30s");
});

test("looksLikeCron: friendly shape check, not full validation", () => {
  assert.equal(looksLikeCron("0 9 * * 1-5"), true);
  assert.equal(looksLikeCron("*/15 * * * *"), true);
  assert.equal(looksLikeCron("0 9 * *"), false); // only 4 fields
  assert.equal(looksLikeCron("0 9 * * 1 extra"), false); // 6 fields
  assert.equal(looksLikeCron(""), false);
});

test("buildTrigger: once", () => {
  const ok = buildTrigger("once", { at: "2026-07-27T09:00" });
  assert.equal(ok.trigger.kind, "once");
  assert.ok(ok.trigger.at.endsWith("Z")); // normalized to an ISO instant

  const bad = buildTrigger("once", { at: "" });
  assert.ok(bad.error);
});

test("buildTrigger: interval and heartbeat", () => {
  assert.deepEqual(buildTrigger("interval", { every: "15m" }).trigger, { kind: "interval", everySeconds: 900 });
  assert.deepEqual(buildTrigger("heartbeat", { every: "1h" }).trigger, { kind: "heartbeat", everySeconds: 3600 });
  assert.ok(buildTrigger("interval", { every: "bogus" }).error);
});

test("buildTrigger: cron validates shape and fills a default time zone", () => {
  const ok = buildTrigger("cron", { expression: "0 9 * * 1-5", timeZone: "Europe/Paris" });
  assert.deepEqual(ok.trigger, { kind: "cron", expression: "0 9 * * 1-5", timeZone: "Europe/Paris" });

  const bad = buildTrigger("cron", { expression: "not a cron" });
  assert.ok(bad.error);
});

test("buildTrigger: unknown kind fails closed with an error, never throws", () => {
  assert.doesNotThrow(() => buildTrigger("bogus", {}));
  assert.ok(buildTrigger("bogus", {}).error);
});

test("triggerSummary: one-liners for every documented kind", () => {
  assert.equal(triggerSummary({ kind: "interval", everySeconds: 900 }), "Every 15m");
  assert.equal(triggerSummary({ kind: "heartbeat", everySeconds: 900 }), "Every 15m while idle");
  assert.equal(triggerSummary({ kind: "cron", expression: "0 9 * * 1-5", timeZone: "UTC" }), "Cron 0 9 * * 1-5 (UTC)");
  assert.ok(triggerSummary({ kind: "once", at: "2026-07-27T09:00:00Z" }).startsWith("Once at"));
});

test("triggerSummary: forward-compatible with an unknown trigger kind", () => {
  assert.doesNotThrow(() => triggerSummary({ kind: "future-kind" }));
  assert.match(triggerSummary({ kind: "future-kind" }), /Unknown trigger/);
  assert.equal(triggerSummary(null), "");
});
