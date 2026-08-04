// Agents write markdown, so the app has to read markdown.
//
// Hand-written rather than pulled from npm for two reasons. It renders to React
// elements instead of an HTML string, so there is no `dangerouslySetInnerHTML`
// anywhere and a hostile message cannot become markup. And it is written to be
// correct on *partial* input: a reply is rewritten several times a second while
// the agent is still typing, so an unclosed fence, a dangling `**` or half a
// table has to render as something calm rather than flickering into garbage.

import type { ReactNode } from "react";

// --- blocks -----------------------------------------------------------------

type Block =
  | { type: "paragraph"; text: string }
  | { type: "heading"; level: number; text: string }
  | { type: "code"; lang: string; text: string; open: boolean }
  | { type: "quote"; blocks: Block[] }
  | { type: "list"; ordered: boolean; start: number; items: ListItem[] }
  | { type: "table"; header: string[]; align: Align[]; rows: string[][] }
  | { type: "rule" };

interface ListItem {
  blocks: Block[];
  /// `- [x] done` — a checkbox the agent ticked, not a literal bracket.
  checked?: boolean;
}

type Align = "left" | "center" | "right";

const FENCE = /^(\s*)(`{3,}|~{3,})\s*([\w+-]*)\s*$/;
const HEADING = /^(#{1,6})\s+(.*)$/;
const RULE = /^\s{0,3}([-*_])\s*(\1\s*){2,}$/;
const BULLET = /^(\s*)([-*+])\s+(.*)$/;
const NUMBER = /^(\s*)(\d{1,9})[.)]\s+(.*)$/;
const QUOTE = /^\s{0,3}>\s?(.*)$/;
const TASK = /^\[([ xX])\]\s+(.*)$/;

export function parseBlocks(source: string): Block[] {
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  return parseLines(lines);
}

function parseLines(lines: string[]): Block[] {
  const blocks: Block[] = [];
  let index = 0;

  const paragraph: string[] = [];
  const flush = () => {
    if (paragraph.length) {
      blocks.push({ type: "paragraph", text: paragraph.join("\n") });
      paragraph.length = 0;
    }
  };

  while (index < lines.length) {
    const line = lines[index];

    if (!line.trim()) {
      flush();
      index += 1;
      continue;
    }

    const fence = line.match(FENCE);
    if (fence) {
      flush();
      const marker = fence[2][0];
      const body: string[] = [];
      index += 1;
      let closed = false;
      while (index < lines.length) {
        const candidate = lines[index].match(FENCE);
        if (candidate && candidate[2][0] === marker) {
          closed = true;
          index += 1;
          break;
        }
        body.push(lines[index]);
        index += 1;
      }
      blocks.push({
        type: "code",
        lang: fence[3],
        text: body.join("\n"),
        // Still being typed: the caller can show it as live output rather than
        // as a finished block.
        open: !closed,
      });
      continue;
    }

    const heading = line.match(HEADING);
    if (heading) {
      flush();
      blocks.push({
        type: "heading",
        level: heading[1].length,
        text: heading[2].replace(/\s+#+\s*$/, ""),
      });
      index += 1;
      continue;
    }

    if (RULE.test(line)) {
      flush();
      blocks.push({ type: "rule" });
      index += 1;
      continue;
    }

    if (QUOTE.test(line)) {
      flush();
      const inner: string[] = [];
      while (index < lines.length) {
        const match = lines[index].match(QUOTE);
        if (!match) {
          // A lazy continuation line belongs to the quote's last paragraph.
          if (lines[index].trim() && inner.length) {
            inner.push(lines[index]);
            index += 1;
            continue;
          }
          break;
        }
        inner.push(match[1]);
        index += 1;
      }
      blocks.push({ type: "quote", blocks: parseLines(inner) });
      continue;
    }

    if (BULLET.test(line) || NUMBER.test(line)) {
      flush();
      const [list, next] = parseList(lines, index);
      blocks.push(list);
      index = next;
      continue;
    }

    const table = parseTable(lines, index);
    if (table) {
      flush();
      blocks.push(table[0]);
      index = table[1];
      continue;
    }

    paragraph.push(line);
    index += 1;
  }

  flush();
  return blocks;
}

/// One list, consuming every sibling item and everything indented under them.
/// Nested lists come back through `parseLines` on the de-indented content.
function parseList(lines: string[], start: number): [Block, number] {
  const first = lines[start].match(BULLET) ?? lines[start].match(NUMBER)!;
  const ordered = !BULLET.test(lines[start]);
  const baseIndent = first[1].length;
  const items: ListItem[] = [];
  let index = start;

  while (index < lines.length) {
    const line = lines[index];
    const match = line.match(BULLET) ?? line.match(NUMBER);
    const isOrdered = match ? !BULLET.test(line) : false;

    if (!match || match[1].length !== baseIndent || isOrdered !== ordered) {
      // Blank lines inside a list are only a break if what follows is not part
      // of the list any more.
      if (!line.trim()) {
        const following = lines[index + 1] ?? "";
        const continues =
          following.match(BULLET)?.[1].length === baseIndent ||
          following.match(NUMBER)?.[1].length === baseIndent ||
          (following.trim() !== "" &&
            following.length - following.trimStart().length > baseIndent);
        if (continues) {
          index += 1;
          continue;
        }
      }
      break;
    }

    const own: string[] = [match[3]];
    index += 1;
    // Everything indented past the marker is this item's body.
    const contentIndent = baseIndent + match[2].length + 1;
    while (index < lines.length) {
      const candidate = lines[index];
      if (!candidate.trim()) {
        const following = lines[index + 1] ?? "";
        const indent = following.length - following.trimStart().length;
        if (following.trim() && indent >= contentIndent) {
          own.push("");
          index += 1;
          continue;
        }
        break;
      }
      const indent = candidate.length - candidate.trimStart().length;
      if (indent < contentIndent) break;
      own.push(candidate.slice(contentIndent));
      index += 1;
    }

    const task = own[0].match(TASK);
    if (task) own[0] = task[2];
    items.push({
      blocks: parseLines(own),
      checked: task ? task[1].toLowerCase() === "x" : undefined,
    });
  }

  return [
    {
      type: "list",
      ordered,
      start: ordered ? Number(first[2]) : 1,
      items,
    },
    index,
  ];
}

/// A pipe table, but only when the delimiter row is actually there — a lone
/// line with a `|` in it is prose, not a one-column table.
function parseTable(lines: string[], start: number): [Block, number] | null {
  const header = lines[start];
  const delimiter = lines[start + 1];
  if (!header?.includes("|") || !delimiter) return null;
  if (!/^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/.test(delimiter)) {
    return null;
  }

  const cells = (line: string) =>
    line
      .trim()
      .replace(/^\|/, "")
      .replace(/\|$/, "")
      .split(/(?<!\\)\|/)
      .map((cell) => cell.trim());

  const head = cells(header);
  const align: Align[] = cells(delimiter).map((spec) => {
    const left = spec.startsWith(":");
    const right = spec.endsWith(":");
    if (left && right) return "center";
    if (right) return "right";
    return "left";
  });

  const rows: string[][] = [];
  let index = start + 2;
  while (index < lines.length && lines[index].trim() && lines[index].includes("|")) {
    const row = cells(lines[index]);
    while (row.length < head.length) row.push("");
    rows.push(row.slice(0, head.length));
    index += 1;
  }

  return [{ type: "table", header: head, align, rows }, index];
}

// --- inline -----------------------------------------------------------------

export interface InlineOptions {
  /// Handles that resolve to a real member, so `@nobody` stays plain text.
  handles?: Set<string>;
  onMention?: (handle: string) => void;
}

/// Only schemes that can't execute anything. A `javascript:` href in an agent's
/// output should read as text, not as a live link.
function safeHref(url: string): string | undefined {
  const trimmed = url.trim();
  if (/^(https?:|mailto:)/i.test(trimmed)) return trimmed;
  if (trimmed.startsWith("/") || trimmed.startsWith("#")) return undefined;
  if (/^[a-z][a-z0-9+.-]*:/i.test(trimmed)) return undefined;
  return `https://${trimmed}`;
}

const INLINE = new RegExp(
  [
    "(`+)([\\s\\S]*?)\\1", // code span
    "!?\\[([^\\]]*)\\]\\(([^()\\s]*(?:\\([^()]*\\)[^()\\s]*)*)(?:\\s+\"[^\"]*\")?\\)", // link
    "\\*\\*\\*([\\s\\S]+?)\\*\\*\\*", // bold italic
    "\\*\\*([\\s\\S]+?)\\*\\*", // bold
    "__([\\s\\S]+?)__",
    "(?<![\\w*])\\*(?!\\s)([\\s\\S]+?)(?<!\\s)\\*(?![\\w*])", // italic
    "(?<![\\w_])_(?!\\s)([\\s\\S]+?)(?<!\\s)_(?![\\w_])",
    "~~([\\s\\S]+?)~~", // strikethrough
    "<(https?://[^>\\s]+)>", // autolink
    "(?<![\\w/])(https?://[^\\s<>()\\[\\]]+[^\\s<>()\\[\\].,;:!?'\"])", // bare url
    "@([a-z0-9][\\w-]*)", // mention
  ].join("|"),
  "gi",
);

export function renderInline(
  text: string,
  options: InlineOptions = {},
  keyPrefix = "i",
): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let key = 0;

  const push = (node: ReactNode) => out.push(node);

  // A newline inside a paragraph is a line break, not whitespace. Strict
  // markdown would swallow it, but this is a chat window: people press Return
  // to start a new line and expect a new line, and an agent laying out a short
  // list without blank lines between the items means exactly what it looks
  // like. Done here rather than per-paragraph so a break inside **bold** still
  // breaks and still stays bold.
  const plain = (value: string) => {
    if (!value) return;
    const lines = value.split("\n");
    lines.forEach((line, index) => {
      if (index > 0) push(<br key={`${keyPrefix}-b${key++}`} />);
      if (line) push(<span key={`${keyPrefix}-t${key++}`}>{line}</span>);
    });
  };

  INLINE.lastIndex = 0;
  for (const match of text.matchAll(INLINE)) {
    const at = match.index ?? 0;
    plain(text.slice(last, at));
    last = at + match[0].length;
    const k = `${keyPrefix}-m${key++}`;

    const [
      ,
      ,
      code,
      linkText,
      linkUrl,
      boldItalic,
      boldStar,
      boldUnderscore,
      italicStar,
      italicUnderscore,
      struck,
      autolink,
      bareUrl,
      mention,
    ] = match;

    if (code !== undefined) {
      push(<code key={k}>{code.trim()}</code>);
    } else if (linkUrl !== undefined) {
      const href = safeHref(linkUrl);
      const label = linkText || linkUrl;
      push(
        href ? (
          <a key={k} href={href} target="_blank" rel="noreferrer noopener">
            {renderInline(label, options, k)}
          </a>
        ) : (
          <span key={k}>{label}</span>
        ),
      );
    } else if (boldItalic !== undefined) {
      push(
        <strong key={k}>
          <em>{renderInline(boldItalic, options, k)}</em>
        </strong>,
      );
    } else if (boldStar !== undefined || boldUnderscore !== undefined) {
      push(
        <strong key={k}>
          {renderInline(boldStar ?? boldUnderscore, options, k)}
        </strong>,
      );
    } else if (italicStar !== undefined || italicUnderscore !== undefined) {
      push(<em key={k}>{renderInline(italicStar ?? italicUnderscore, options, k)}</em>);
    } else if (struck !== undefined) {
      push(<del key={k}>{renderInline(struck, options, k)}</del>);
    } else if (autolink !== undefined || bareUrl !== undefined) {
      const url = (autolink ?? bareUrl)!;
      push(
        <a key={k} href={url} target="_blank" rel="noreferrer noopener">
          {url.replace(/^https?:\/\//, "")}
        </a>,
      );
    } else if (mention !== undefined) {
      const known = options.handles?.has(mention.toLowerCase());
      push(
        known ? (
          <span
            key={k}
            className="mention"
            onClick={
              options.onMention
                ? (event) => {
                    event.stopPropagation();
                    options.onMention?.(mention);
                  }
                : undefined
            }
          >
            @{mention}
          </span>
        ) : (
          <span key={k}>@{mention}</span>
        ),
      );
    }
  }

  plain(text.slice(last));
  return out;
}
