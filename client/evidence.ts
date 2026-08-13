// What a piece of evidence actually is, and enough CSV to draw one as a table.
//
// Pure, so both clients agree on how to treat an attachment and so the parser
// can be tested without a browser.

export type EvidenceKind =
  | "image"
  | "video"
  | "markdown"
  | "html"
  | "csv"
  | "text"
  | "file";

const BY_EXTENSION: Record<string, EvidenceKind> = {
  md: "markdown",
  markdown: "markdown",
  html: "html",
  htm: "html",
  csv: "csv",
  tsv: "csv",
  txt: "text",
  log: "text",
  json: "text",
  yaml: "text",
  yml: "text",
};

/// Both signals matter. The relay guesses a MIME type from the file name, but
/// a file dropped into the composer arrives with whatever the browser thought,
/// which for Markdown is routinely nothing at all.
export function evidenceKind(mime: string, fileName: string): EvidenceKind {
  const type = mime.toLowerCase();
  if (type.startsWith("image/")) return "image";
  if (type.startsWith("video/")) return "video";

  const extension = fileName.toLowerCase().split(".").pop() ?? "";
  const named = BY_EXTENSION[extension];
  if (named) return named;

  if (type === "text/markdown") return "markdown";
  if (type === "text/html") return "html";
  if (type === "text/csv" || type === "text/tab-separated-values") return "csv";
  if (type.startsWith("text/") || type === "application/json") return "text";
  return "file";
}

export function isTextEvidence(kind: EvidenceKind) {
  return kind === "markdown" || kind === "html" || kind === "csv" || kind === "text";
}

/// Enough CSV for evidence: quoted fields, doubled quotes inside them, and
/// separators or newlines that only look like structure.
///
/// ponytail: no delimiter sniffing and no type coercion. Add both the day a
/// report arrives semicolon-separated or a column needs to sort as numbers.
export function parseTable(text: string, separator = ","): string[][] {
  const rows: string[][] = [[""]];
  let quoted = false;
  const append = (char: string) => {
    const row = rows[rows.length - 1];
    row[row.length - 1] += char;
  };

  for (let at = 0; at < text.length; at++) {
    const char = text[at];
    if (char === "\r") continue;
    if (quoted) {
      if (char !== '"') append(char);
      else if (text[at + 1] === '"') {
        append('"');
        at++;
      } else quoted = false;
      continue;
    }
    if (char === '"') quoted = true;
    else if (char === separator) rows[rows.length - 1].push("");
    else if (char === "\n") rows.push([""]);
    else append(char);
  }

  const last = rows[rows.length - 1];
  if (last.length === 1 && last[0] === "") rows.pop();
  return rows;
}

export function separatorFor(fileName: string) {
  return fileName.toLowerCase().endsWith(".tsv") ? "\t" : ",";
}

/// Flint names this one chart `Boxplot`, while the public Patchwork format
/// documents the ordinary `Box Plot`. Accept what agents are told to send.
export function normalizedChartSpec(spec: unknown): unknown {
  if (!spec || typeof spec !== "object" || Array.isArray(spec)) return spec;
  const chart = (spec as { chart_spec?: unknown }).chart_spec;
  if (!chart || typeof chart !== "object" || Array.isArray(chart)) return spec;
  if ((chart as { chartType?: unknown }).chartType !== "Box Plot") return spec;
  return { ...spec, chart_spec: { ...chart, chartType: "Boxplot" } };
}
