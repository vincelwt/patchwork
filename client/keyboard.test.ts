import assert from "node:assert/strict";
import test from "node:test";

import { keyboardInset } from "./keyboard.ts";

test("the keyboard inset accounts for where each platform measures from", () => {
  // Android reports the height above the system bars, so it stacks on the
  // bar's own inset: a 300pt keyboard over a 24pt navigation bar needs 300.
  assert.equal(keyboardInset(300, 24, false), 300);
  // iOS reports it from the bottom of the window, so the safe area a bar
  // already reserves is room the keyboard has taken back.
  assert.equal(keyboardInset(300, 34, true), 266);
  // A keyboard shorter than the reserved inset never pulls a bar downwards.
  assert.equal(keyboardInset(20, 34, true), 0);
  // No keyboard, no inset, on either platform.
  assert.equal(keyboardInset(0, 34, true), 0);
  assert.equal(keyboardInset(0, 24, false), 0);
});
