// Evidence read where it sits: a Markdown report, a table, a page or a log
// renders in place instead of asking to be downloaded first, and a screenshot
// opens big enough to read the thing it was taken to show.

import { useEffect, useState } from "react";
import { evidenceKind, parseTable, separatorFor } from "@client/evidence";
import type { Attachment } from "@client/types";
import { useApi } from "../lib/store";
import { CloseIcon, Spinner } from "./icons";
import { Markdown } from "./Markdown";

/// Past this a browser lays out far more than anybody is going to read, and
/// the download button is right there.
const MAX_CHARS = 400_000;
const MAX_ROWS = 500;

/// Markdown, CSV, HTML and plain text, fetched as text because the relay wants
/// a bearer token that an `src` attribute cannot carry.
export function TextEvidence({ attachment }: { attachment: Attachment }) {
  const api = useApi();
  const [text, setText] = useState<string>();
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setText(undefined);
    setFailed(false);
    void api
      .file(attachment.url)
      .then((blob) => blob.text())
      .then((body) => {
        if (!cancelled) setText(body);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, [api, attachment.url]);

  if (failed) {
    return <div className="review-unavailable">That file could not be read.</div>;
  }
  if (text === undefined) {
    return (
      <div className="review-unavailable">
        <Spinner size={14} />
      </div>
    );
  }

  const kind = evidenceKind(attachment.mime, attachment.file_name);
  if (kind === "html") {
    // Somebody else's HTML: worth showing, not worth trusting. No scripts, no
    // same-origin, so a report cannot reach the workspace it is evidence for.
    return (
      <iframe
        className="review-frame"
        sandbox=""
        srcDoc={text}
        title={attachment.file_name}
      />
    );
  }

  const clipped = text.length > MAX_CHARS;
  const body = clipped ? text.slice(0, MAX_CHARS) : text;

  return (
    <div className="evidence-view">
      {kind === "markdown" ? (
        <Markdown body={body} />
      ) : kind === "csv" ? (
        <CsvTable rows={parseTable(body, separatorFor(attachment.file_name))} />
      ) : (
        <pre className="evidence-pre">{body}</pre>
      )}
      {clipped && (
        <p className="evidence-note">
          Showing the first {MAX_CHARS.toLocaleString()} characters. Download the file
          for the rest.
        </p>
      )}
    </div>
  );
}

function CsvTable({ rows }: { rows: string[][] }) {
  const [header, ...body] = rows;
  if (!header) return <p className="evidence-note">That file is empty.</p>;
  const shown = body.slice(0, MAX_ROWS);

  return (
    <div className="md">
      <div className="md-table-scroll">
        <table>
          <thead>
            <tr>
              {header.map((cell, index) => (
                <th key={index}>{cell}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {shown.map((row, index) => (
              <tr key={index}>
                {row.map((cell, at) => (
                  <td key={at}>{cell}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {body.length > shown.length && (
        <p className="evidence-note">
          Showing {shown.length} of {body.length} rows.
        </p>
      )}
    </div>
  );
}

/// A screenshot is usually evidence of something small inside it — a label, a
/// number, one wrong pixel — so an image opens over the app and zooms. Scroll
/// pans, ⌘/ctrl-scroll and pinch zoom, clicking the image steps through it.
export function Lightbox({
  url,
  alt,
  onClose,
}: {
  url: string;
  alt: string;
  onClose: () => void;
}) {
  const [scale, setScale] = useState(1);
  const zoomBy = (factor: number) =>
    setScale((current) => Math.min(8, Math.max(1, current * factor)));

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="lightbox" onMouseDown={onClose}>
      <div className="lightbox-bar" onMouseDown={(event) => event.stopPropagation()}>
        <span className="name">{alt}</span>
        <button
          className="icon-button"
          title="Zoom out"
          aria-label="Zoom out"
          disabled={scale <= 1}
          onClick={() => zoomBy(1 / 1.5)}
        >
          −
        </button>
        <span className="scale">{Math.round(scale * 100)}%</span>
        <button
          className="icon-button"
          title="Zoom in"
          aria-label="Zoom in"
          disabled={scale >= 8}
          onClick={() => zoomBy(1.5)}
        >
          +
        </button>
        <button className="icon-button" title="Close" aria-label="Close" onClick={onClose}>
          <CloseIcon size={14} />
        </button>
      </div>
      <div
        className="lightbox-stage"
        onWheel={(event) => {
          // A trackpad pinch arrives as a ctrl wheel. A plain wheel is left
          // alone because that is how you pan an image bigger than the window.
          if (!event.ctrlKey && !event.metaKey) return;
          zoomBy(event.deltaY < 0 ? 1.15 : 1 / 1.15);
        }}
      >
        <img
          src={url}
          alt={alt}
          className={scale > 1 ? "zoomed" : ""}
          style={scale > 1 ? { width: `${scale * 100}%` } : undefined}
          onMouseDown={(event) => event.stopPropagation()}
          onClick={() => zoomBy(scale >= 8 ? 1 / scale : 2)}
        />
      </div>
    </div>
  );
}
