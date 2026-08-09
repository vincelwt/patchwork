// Rendering the blocks `lib/markdown` parsed.
//
// Kept apart from the parser so the parser stays testable prose-in, data-out,
// and so this file can stay about presentation: how a code block offers itself
// to be copied, how a table scrolls, how a half-finished fence behaves.

import { memo, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { parseBlocks, renderInline } from "../lib/markdown";
import type { InlineOptions } from "../lib/markdown";
import { CheckIcon, CopyIcon } from "./icons";

export const Markdown = memo(function Markdown({
  body,
  handles,
  className = "",
  compact,
}: {
  body: string;
  handles?: Set<string>;
  className?: string;
  /// Inside a card or a run log, where a full typographic scale would shout.
  compact?: boolean;
}) {
  const blocks = useMemo(() => parseBlocks(body), [body]);
  const options: InlineOptions = useMemo(() => ({ handles }), [handles]);

  return (
    <div className={`md${compact ? " compact" : ""}${className ? ` ${className}` : ""}`}>
      {blocks.map((block, index) => (
        <BlockView key={index} block={block} options={options} />
      ))}
    </div>
  );
});

type Block = ReturnType<typeof parseBlocks>[number];

function BlockView({ block, options }: { block: Block; options: InlineOptions }): ReactNode {
  switch (block.type) {
    case "paragraph":
      return <p>{renderInline(block.text, options)}</p>;

    case "heading": {
      const level = Math.min(block.level, 6);
      const Tag = `h${level}` as "h1";
      return <Tag>{renderInline(block.text, options)}</Tag>;
    }

    case "code":
      return <CodeBlock lang={block.lang} text={block.text} open={block.open} />;

    case "rule":
      return <hr />;

    case "quote":
      return (
        <blockquote>
          {block.blocks.map((inner, index) => (
            <BlockView key={index} block={inner} options={options} />
          ))}
        </blockquote>
      );

    case "list": {
      const items = block.items.map((item, index) => (
        <li key={index} className={item.task ? "task" : ""}>
          {item.task && (
            <span
              className={`md-check ${item.task}`}
              role="checkbox"
              aria-checked={
                item.task === "progress" ? "mixed" : item.task === "checked"
              }
              aria-label={`${
                item.task === "checked"
                  ? "Completed"
                  : item.task === "progress"
                    ? "In-progress"
                    : "Incomplete"
              } checklist item`}
            >
              {item.task === "checked" && <CheckIcon size={11} />}
            </span>
          )}
          <span className="md-item">
            {item.blocks.map((inner, at) => (
              <BlockView key={at} block={inner} options={options} />
            ))}
          </span>
        </li>
      ));
      return block.ordered ? (
        <ol start={block.start}>{items}</ol>
      ) : (
        <ul>{items}</ul>
      );
    }

    case "table":
      return (
        <div className="md-table-scroll">
          <table>
            <thead>
              <tr>
                {block.header.map((cell, index) => (
                  <th key={index} style={{ textAlign: block.align[index] ?? "left" }}>
                    {renderInline(cell, options)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {block.rows.map((row, index) => (
                <tr key={index}>
                  {row.map((cell, at) => (
                    <td key={at} style={{ textAlign: block.align[at] ?? "left" }}>
                      {renderInline(cell, options)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
  }
}

/// Code an agent wrote is nearly always code you are about to run, so copying
/// it is the one affordance worth spending pixels on.
function CodeBlock({
  lang,
  text,
  open,
}: {
  lang: string;
  text: string;
  open: boolean;
}) {
  const [copied, setCopied] = useState(false);

  return (
    <div className={`md-code${open ? " streaming" : ""}`}>
      <div className="md-code-head">
        <span className="lang">{lang || "text"}</span>
        <span className="spacer" />
        <button
          className="icon-button small"
          title={copied ? "Copied" : "Copy"}
          onClick={() => {
            void navigator.clipboard.writeText(text);
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1400);
          }}
        >
          {copied ? <CheckIcon size={13} /> : <CopyIcon size={13} />}
        </button>
      </div>
      <pre>
        <code>{text}</code>
      </pre>
    </div>
  );
}
