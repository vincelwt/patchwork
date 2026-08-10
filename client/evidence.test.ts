import assert from "node:assert/strict";
import test from "node:test";

import { evidenceKind, parseTable, separatorFor } from "./evidence.ts";

test("the file name decides whenever the MIME type is vague", () => {
  assert.equal(evidenceKind("application/octet-stream", "report.md"), "markdown");
  assert.equal(evidenceKind("", "index.html"), "html");
  assert.equal(evidenceKind("text/plain", "totals.csv"), "csv");
  assert.equal(evidenceKind("text/csv", "totals.csv"), "csv");
  assert.equal(evidenceKind("text/plain", "run.log"), "text");
  assert.equal(evidenceKind("application/json", "trace"), "text");
  assert.equal(evidenceKind("image/png", "shot.png"), "image");
  assert.equal(evidenceKind("video/mp4", "walkthrough.mp4"), "video");
  assert.equal(evidenceKind("application/pdf", "spec.pdf"), "file");
});

test("quoted CSV fields keep their separators, quotes and newlines", () => {
  const rows = parseTable('a,b\n"x,1","he said ""hi"""\n"two\nlines",z\n');
  assert.deepEqual(rows, [
    ["a", "b"],
    ["x,1", 'he said "hi"'],
    ["two\nlines", "z"],
  ]);
});

test("a tab separated table is the same parser with another separator", () => {
  assert.equal(separatorFor("totals.tsv"), "\t");
  assert.equal(separatorFor("totals.csv"), ",");
  assert.deepEqual(parseTable("a\tb\r\n1\t2", "\t"), [
    ["a", "b"],
    ["1", "2"],
  ]);
});

test("empty cells and an empty file stay empty rather than disappearing", () => {
  assert.deepEqual(parseTable("a,,c\n"), [["a", "", "c"]]);
  assert.deepEqual(parseTable(""), []);
});
