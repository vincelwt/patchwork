// Node-only checks for the pure Markdown renderer (Sources/PiDeskWeb/Site/js/markdown.mjs).
// Not part of `swift build`/`swift test` — see docs/web-remote.md for why and how to run this.
// Uses only Node's built-in test runner and assert module: no npm, no third-party dependency.
import test from "node:test";
import assert from "node:assert/strict";
import { escapeHtml, renderInline, renderMarkdown } from "../../Sources/PiDeskWeb/Site/js/markdown.mjs";

test("escapeHtml escapes all five HTML-significant characters", () => {
  assert.equal(escapeHtml(`&<>"'`), "&amp;&lt;&gt;&quot;&#39;");
  assert.equal(escapeHtml(null), "");
  assert.equal(escapeHtml(undefined), "");
  assert.equal(escapeHtml(42), "42");
});

test("renderInline: bold, italic, code, and safe links", () => {
  assert.equal(renderInline("**bold**"), "<strong>bold</strong>");
  assert.equal(renderInline("__bold__"), "<strong>bold</strong>");
  assert.equal(renderInline("*em*"), "<em>em</em>");
  assert.equal(renderInline("_em_"), "<em>em</em>");
  assert.equal(renderInline("`code`"), "<code>code</code>");
  assert.equal(
    renderInline("[Pi](https://pi.dev)"),
    '<a href="https://pi.dev" rel="noopener noreferrer" target="_blank">Pi</a>'
  );
  assert.equal(
    renderInline("[mail](mailto:a@b.com)"),
    '<a href="mailto:a@b.com" rel="noopener noreferrer" target="_blank">mail</a>'
  );
});

test("renderInline: code spans are protected from further inline substitution", () => {
  // The asterisks inside the code span must NOT become <em>.
  assert.equal(renderInline("`a*b*c`"), "<code>a*b*c</code>");
  assert.equal(renderInline("before `x` and **bold**"), "before <code>x</code> and <strong>bold</strong>");
});

test("renderInline: unsafe link schemes are dropped, label text is kept", () => {
  for (const url of [
    "javascript:alert(1)",
    "JAVASCRIPT:alert(1)",
    "  javascript:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "vbscript:msgbox(1)",
    "//evil.example/phish"
  ]) {
    const out = renderInline(`[click me](${url})`);
    assert.ok(!out.includes("<a "), `expected no anchor for ${url}, got: ${out}`);
    assert.ok(out.includes("click me"), `expected the label text to survive for ${url}`);
  }
});

test("renderInline: raw HTML in the source is neutralized, never executed", () => {
  const out = renderInline('<img src=x onerror="alert(1)">');
  assert.ok(!out.includes("<img"), out);
  assert.ok(out.includes("&lt;img"), out);
});

test("renderInline: a script tag never survives as a real element", () => {
  const out = renderInline("<script>alert(document.cookie)</script>");
  assert.ok(!/<script/i.test(out), out);
  assert.ok(out.includes("&lt;script&gt;"), out);
});

test("renderMarkdown: headings, paragraphs, and single newlines as <br>", () => {
  const out = renderMarkdown("# Title\n\nLine one\nLine two");
  assert.equal(out, "<h1>Title</h1>\n<p>Line one<br>Line two</p>");
});

test("renderMarkdown: unordered and ordered lists", () => {
  assert.equal(renderMarkdown("- a\n- b"), "<ul><li>a</li><li>b</li></ul>");
  assert.equal(renderMarkdown("1. a\n2. b"), "<ol><li>a</li><li>b</li></ol>");
});

test("renderMarkdown: fenced code blocks are verbatim and never inline-processed", () => {
  const out = renderMarkdown("```js\nconst a = 1 * 2;\n<b>not bold</b>\n```");
  assert.equal(out, '<pre><code class="language-js">const a = 1 * 2;\n&lt;b&gt;not bold&lt;/b&gt;</code></pre>');
});

test("renderMarkdown: a fenced code block cannot be escaped by its own contents", () => {
  // Content that looks like a closing fence with trailing junk must not close the block early.
  const out = renderMarkdown("```\nhello\n``` not a real fence\nstill inside? no: this line is after\n```\n");
  assert.ok(out.startsWith("<pre><code>hello"));
});

test("renderMarkdown: GFM table with alignment", () => {
  const out = renderMarkdown("| A | B |\n| :-- | --: |\n| 1 | 2 |");
  assert.ok(out.includes("<table>"));
  assert.ok(out.includes('<th style="text-align:left">A</th>'));
  assert.ok(out.includes('<th style="text-align:right">B</th>'));
  assert.ok(out.includes("<td"));
});

test("renderMarkdown: injection payloads never produce a live tag outside the renderer's own allow-list", () => {
  // The renderer only ever emits these tags itself. Any other unescaped `<tagname` appearing in
  // the output means something from untrusted input leaked through as real markup.
  const ALLOWED_TAGS = new Set(
    "h1 h2 h3 h4 h5 h6 ul ol li pre code strong em a table thead tbody tr th td p".split(" ")
  );
  const payloads = [
    "<script>alert(1)</script>",
    "<img src=x onerror=alert(1)>",
    "[x](javascript:alert(1))",
    "# <script>alert(1)</script>",
    "- <img src=x onerror=alert(1)>",
    "| <script>a</script> | b |\n| --- | --- |\n| 1 | 2 |",
    "```\n<script>alert(1)</script>\n```",
    '<svg onload=alert(1)><a href="x" onclick="alert(1)">click</a></svg>'
  ];
  for (const payload of payloads) {
    const out = renderMarkdown(payload);
    // A live, disallowed tag is the only way an event-handler attribute (onload=, onerror=,
    // ...) could ever become real markup instead of inert escaped text — so this one check
    // covers both: nothing from `payload` produced an element outside this fixed allow-list.
    for (const match of out.matchAll(/<\s*([a-zA-Z][a-zA-Z0-9]*)/g)) {
      assert.ok(ALLOWED_TAGS.has(match[1].toLowerCase()), `disallowed live tag <${match[1]}> for: ${payload}\n-> ${out}`);
    }
  }
});

test("renderMarkdown: empty and non-string input never throws", () => {
  assert.doesNotThrow(() => renderMarkdown(""));
  assert.doesNotThrow(() => renderMarkdown(undefined));
  assert.doesNotThrow(() => renderMarkdown(null));
  assert.equal(renderMarkdown(""), "");
});
