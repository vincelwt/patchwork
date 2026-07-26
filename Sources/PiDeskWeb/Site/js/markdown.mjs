// Small, safe Markdown -> HTML renderer for assistant/tool text.
//
// Threat model: `source` is model output, never trusted. Every code path escapes raw text
// before any HTML is produced; the only unescaped substrings ever concatenated into the result
// are literal tag strings this file writes itself (e.g. "<strong>"), never text derived from
// `source`. Links are allow-listed by scheme (http/https/mailto only) so `javascript:`, `data:`,
// and similar schemes can never become a clickable href. There is no innerHTML call in this
// file — callers are expected to assign the returned string to `.innerHTML` exactly once, which
// is safe because the string is already fully escaped-and-controlled by the time it is returned.
//
// Deliberately out of scope (kept small on purpose, see docs/web-remote.md): nested lists, bare
// URL autolinking, blockquotes, escaped `\|` inside table cells, and setext (`===`/`---`)
// headings. None of these affect safety, only formatting fidelity for rarer inputs.

const ESCAPE_MAP = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Escapes the five HTML-significant characters. Never returns anything else unescaped. */
export function escapeHtml(value) {
  const str = value === null || value === undefined ? "" : String(value);
  return str.replace(/[&<>"']/g, (ch) => ESCAPE_MAP[ch]);
}

// Only these schemes may become a clickable link. Allow-list, not a deny-list, so an unknown or
// obfuscated scheme (`javascript:`, `data:`, `vbscript:`, mixed-case tricks, ...) fails closed.
function isSafeUrl(url) {
  return /^(https:|http:|mailto:)/i.test(url.trim());
}

/**
 * Renders one span of raw inline text (a paragraph, list item, heading, or table cell) to safe
 * HTML: escapes first, then layers code spans, links, bold, and italic on top of the already-
 * escaped text. Code span contents are protected from further substitution via a placeholder
 * swapped back in as the very last step, so `` `a*b*` `` never has its asterisks reinterpreted.
 */
export function renderInline(raw) {
  const spans = [];
  // NUL is never produced by escapeHtml and stripped from the input first, so it is safe to use
  // as an exclusive placeholder delimiter for protected code-span content.
  let text = escapeHtml(raw).replace(/\u0000/g, "");
  text = text.replace(/`([^`\n]+)`/g, (_, code) => {
    spans.push(code);
    return `\u0000${spans.length - 1}\u0000`;
  });
  text = text.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (whole, label, url) =>
    isSafeUrl(url) ? `<a href="${url}" rel="noopener noreferrer" target="_blank">${label}</a>` : label
  );
  text = text.replace(/\*\*([^*\n]+)\*\*|__([^_\n]+)__/g, (_, a, b) => `<strong>${a ?? b}</strong>`);
  text = text.replace(/\*([^*\n]+)\*|_([^_\n]+)_/g, (_, a, b) => `<em>${a ?? b}</em>`);
  text = text.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${spans[Number(i)]}</code>`);
  return text;
}

const HEADING_RE = /^(#{1,6})\s+(.+)$/;
const UL_RE = /^\s*[-*+]\s+(.*)$/;
const OL_RE = /^\s*\d+[.)]\s+(.*)$/;
const OL_ITEM_RE = /^\s*\d+[.)]\s+(.*)$/;
const FENCE_RE = /^```\s*([A-Za-z0-9_+-]*)\s*$/;
const FENCE_END_RE = /^```\s*$/;
const TABLE_SEP_RE = /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$/;

function splitRow(line) {
  let trimmed = line.trim();
  if (trimmed.startsWith("|")) trimmed = trimmed.slice(1);
  if (trimmed.endsWith("|")) trimmed = trimmed.slice(0, -1);
  return trimmed.split("|").map((cell) => cell.trim());
}

function alignFor(sepCell) {
  const left = sepCell.startsWith(":");
  const right = sepCell.endsWith(":");
  if (left && right) return "center";
  if (right) return "right";
  if (left) return "left";
  return null;
}

/** Renders a full Markdown document to a safe HTML string. See the file header for the model. */
export function renderMarkdown(source) {
  const lines = String(source ?? "").replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (line.trim() === "") {
      i++;
      continue;
    }

    const fence = line.match(FENCE_RE);
    if (fence) {
      const lang = fence[1];
      const body = [];
      i++;
      while (i < lines.length && !FENCE_END_RE.test(lines[i])) {
        body.push(lines[i]);
        i++;
      }
      i++; // consume closing fence (or EOF, harmlessly)
      const classAttr = lang ? ` class="language-${escapeHtml(lang)}"` : "";
      blocks.push(`<pre><code${classAttr}>${escapeHtml(body.join("\n"))}</code></pre>`);
      continue;
    }

    const heading = line.match(HEADING_RE);
    if (heading) {
      const level = heading[1].length;
      blocks.push(`<h${level}>${renderInline(heading[2])}</h${level}>`);
      i++;
      continue;
    }

    if (line.includes("|") && i + 1 < lines.length && TABLE_SEP_RE.test(lines[i + 1])) {
      const headerCells = splitRow(line);
      const aligns = splitRow(lines[i + 1]).map(alignFor);
      i += 2;
      const bodyRows = [];
      while (i < lines.length && lines[i].trim() !== "" && lines[i].includes("|")) {
        bodyRows.push(splitRow(lines[i]));
        i++;
      }
      const th = headerCells
        .map((cell, idx) => `<th${aligns[idx] ? ` style="text-align:${aligns[idx]}"` : ""}>${renderInline(cell)}</th>`)
        .join("");
      const rows = bodyRows
        .map(
          (row) =>
            `<tr>${row
              .map((cell, idx) => `<td${aligns[idx] ? ` style="text-align:${aligns[idx]}"` : ""}>${renderInline(cell)}</td>`)
              .join("")}</tr>`
        )
        .join("");
      blocks.push(`<table><thead><tr>${th}</tr></thead><tbody>${rows}</tbody></table>`);
      continue;
    }

    if (UL_RE.test(line) && !OL_ITEM_RE.test(line)) {
      const items = [];
      while (i < lines.length && UL_RE.test(lines[i])) {
        items.push(renderInline(lines[i].match(UL_RE)[1]));
        i++;
      }
      blocks.push(`<ul>${items.map((it) => `<li>${it}</li>`).join("")}</ul>`);
      continue;
    }

    if (OL_RE.test(line)) {
      const items = [];
      while (i < lines.length && OL_RE.test(lines[i])) {
        items.push(renderInline(lines[i].match(OL_ITEM_RE)[1]));
        i++;
      }
      blocks.push(`<ol>${items.map((it) => `<li>${it}</li>`).join("")}</ol>`);
      continue;
    }

    // Paragraph: consume consecutive plain lines, preserving single newlines as <br> — model
    // output routinely uses single line breaks without a blank line between "paragraphs", and
    // treating each as a hard break reads more correctly than CommonMark's "join with a space".
    const para = [];
    while (
      i < lines.length &&
      lines[i].trim() !== "" &&
      !FENCE_RE.test(lines[i]) &&
      !HEADING_RE.test(lines[i]) &&
      !UL_RE.test(lines[i]) &&
      !OL_RE.test(lines[i]) &&
      !(lines[i].includes("|") && i + 1 < lines.length && TABLE_SEP_RE.test(lines[i + 1]))
    ) {
      para.push(lines[i]);
      i++;
    }
    blocks.push(`<p>${para.map(renderInline).join("<br>")}</p>`);
  }

  return blocks.join("\n");
}
